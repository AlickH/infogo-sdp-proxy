import Foundation
import NetworkExtension

/// 单条 packet flow 上的「包分类器」。
///
/// 合并前：三条隧道各有一个 utun，内核按目的前缀把包送到不同接口。
/// 合并后：只有一条 utun，内核把包交给这里，再由 `PacketDispatcher`
/// 按目的地址分给对应的引擎；引擎回吐的包统一写回同一个 flow。
///
/// 关键约束：
/// - 三条隧道声明的网段互不重叠，所以「最长前缀匹配」不会二义
/// - 每个引擎的 `onOutbound` 回调可能来自不同线程，写 flow 前不加锁也可以
///   （NEPacketTunnelFlow.writePackets 允许并发调用）
final class PacketDispatcher {
    private let flow: NEPacketTunnelFlow
    private let lock = NSLock()
    private var engines: [TunnelEngine] = []
    private var table: [(IPPrefix, TunnelEngine)] = []
    private var running = false

    /// 未按任何前缀命中时的兜底引擎（目前是 SDP 的规则兜底）
    private var fallback: TunnelEngine?

    /// 额外排除出隧道的网段。
    ///
    /// 由 `MergedProvider` 注入：三个引擎自己外联目标的解析结果（SDP 网关、
    /// WG endpoint、TS controlplane）。这些流量由扩展进程自己发起，必须走
    /// 物理网卡，否则会被自己的 utun 吸回去、永远收不到回包。
    private var extraExcludes: [String] = []

    /// 诊断计数，便于在 App 侧确认包确实流经了分类器
    private(set) var inboundCount: UInt64 = 0
    private(set) var outboundCount: UInt64 = 0
    private let counters = DispatchQueue(label: "sdp.dispatcher.counters", attributes: .concurrent)

    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    /// 注册引擎并建立路由表。start() 之前调用。
    func register(_ engines: [TunnelEngine], fallback: TunnelEngine?) {
        lock.lock(); defer { lock.unlock() }
        self.engines = engines
        self.fallback = fallback
        var entries: [(IPPrefix, TunnelEngine)] = []
        for engine in engines {
            for cidr in engine.routes {
                guard let prefix = IPPrefix(cidr: cidr) else { continue }
                entries.append((prefix, engine))
            }
        }
        // 最长前缀优先，保证 /32 的主机路由能盖过 /10 的段路由
        entries.sort { $0.0.prefixLength > $1.0.prefixLength }
        self.table = entries
    }

    /// 注入引擎外联目标的排除网段（必须在 buildSettings() 之前调用）
    func setExtraExcludes(_ cidrs: [String]) {
        lock.lock(); defer { lock.unlock() }
        extraExcludes = cidrs
    }

    /// 把所有启用引擎的路由/地址/DNS 合并成一份网络设置。
    func buildSettings(tunnelRemoteAddress: String = "127.0.0.1") -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)
        let list = lock.withLock { engines }

        let addrs = list.flatMap(\.addresses).filter { !$0.contains(":") }
        if !addrs.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: addrs.map { cidrHost($0) },
                                      subnetMasks: addrs.map { cidrMask($0) })
            var routes: [NEIPv4Route] = []
            for engine in list {
                for cidr in engine.routes where !cidr.contains(":") {
                    routes.append(NEIPv4Route(destinationAddress: cidrHost(cidr),
                                              subnetMask: cidrMask(cidr)))
                }
            }
            ipv4.includedRoutes = routes
            let declared = list.flatMap(\.excludeRoutes)
            let merged = declared + lock.withLock { extraExcludes }
            let excludes = merged.compactMap { cidr -> NEIPv4Route? in
                guard !cidr.contains(":"), let pfx = IPPrefix(cidr: cidr) else { return nil }
                // 回环地址永远不进 utun，把它作为 route 目的地会被 NE 判为非法：
                // "IPv4 routes are invalid: IPv4Route Destination address is loopback"，
                // 整份网络设置会被丢弃（隧道显示已连接但一个包都不走）。
                guard pfx.address != IPPrefix.parseIP("127.0.0.1") else { return nil }
                let bits = pfx.mask.byteSwapped
                let mask = "\((bits >> 24) & 255).\((bits >> 16) & 255).\((bits >> 8) & 255).\(bits & 255)"
                return NEIPv4Route(destinationAddress: cidrHost(cidr), subnetMask: mask)
            }
            if !excludes.isEmpty { ipv4.excludedRoutes = excludes }
            settings.ipv4Settings = ipv4
        }

        let dns = list.flatMap(\.dnsServers)
        if !dns.isEmpty {
            var unique: [String] = []
            for s in dns where !unique.contains(s) { unique.append(s) }
            let d = NEDNSSettings(servers: unique)
            // 只有 Tailscale 需要分域解析；不带 ~（macOS 上 matchDomains 本身即后缀匹配）
            let domains = list.map(\.dnsMatchDomain).filter { !$0.isEmpty }
            if !domains.isEmpty { d.matchDomains = domains }
            settings.dnsSettings = d
        }

        settings.mtu = NSNumber(value: list.map(\.mtu).max() ?? 1280)
        return settings
    }

    /// 启动所有引擎并开始搬包。
    func start(configs: [String: [String: Any]], completion: @escaping (Error?) -> Void) {
        let list = lock.withLock { engines }
        guard !list.isEmpty else { completion(MergedError.noEngine); return }

        for engine in list {
            let name = engine.name
            engine.onOutbound { [weak self] packet in
                guard let self = self else { return }
                self.counters.async(flags: .barrier) { self.outboundCount += 1 }
                let seq = self.bumpOutbound()
                if seq <= 12 || seq % 200 == 0 {
                    Diag.log("outbound", "#\(seq) \(name) \(packet.count)B -> flow")
                }
                let version = (packet.first ?? 0) >> 4
                let af: NSNumber = version == 6 ? 30 : 2
                self.flow.writePackets([packet], withProtocols: [af])
            }
        }

        let group = DispatchGroup()
        var firstError: Error?
        let errLock = NSLock()
        for engine in list {
            group.enter()
            engine.start(config: configs[engine.name] ?? [:]) { err in
                if let err = err {
                    errLock.lock()
                    if firstError == nil { firstError = err }
                    errLock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self = self else { completion(nil); return }
            if let err = firstError { completion(err); return }
            self.running = true
            self.pump()
            completion(nil)
        }
    }

    func stop() {
        running = false
        let list = lock.withLock { engines }
        for e in list { e.stop() }
    }

    /// 控制消息路由：约定首行是 `wg:` / `ts:` / `sdp:` 前缀
    func handleMessage(_ data: Data, completion: @escaping (Data?) -> Void) {
        let list = lock.withLock { engines }
        guard let text = String(data: data, encoding: .utf8),
              let target = list.first(where: { text.hasPrefix($0.name + ":") }),
              let colon = text.firstIndex(of: ":") else {
            // 没前缀时交给第一个引擎，兼容旧的单引擎消息
            if let first = list.first { first.handleMessage(data, completion: completion) }
            else { completion(nil) }
            return
        }
        let body = String(text[text.index(after: colon)...])
        target.handleMessage(Data(body.utf8), completion: completion)
    }

    // MARK: - 搬运

    private func pump() {
        guard running else { return }
        flow.readPackets { [weak self] packets, _ in
            guard let self = self, self.running else { return }
            self.counters.async(flags: .barrier) { self.inboundCount += UInt64(packets.count) }
            for packet in packets {
                guard let dst = IPPrefix.destination(of: packet) else { continue }
                let entries = self.lock.withLock { self.table }
                let engine = entries.first(where: { $0.0.contains(dst) })?.1 ?? self.fallback
                let seq = self.bumpInbound()
                if seq <= 12 || seq % 200 == 0 {
                    let src = IPPrefix.source(of: packet).map(IPPrefix.string) ?? "?"
                    Diag.log("pump", "#\(seq) \(src) -> \(IPPrefix.string(dst)) \(packet.count)B -> \(engine?.name ?? "无引擎,丢弃")")
                }
                engine?.deliver(packet)
            }
            self.pump()
        }
    }

    private var inboundSeq: UInt64 = 0
    private var outboundSeq: UInt64 = 0

    private func bumpInbound() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        inboundSeq += 1
        return inboundSeq
    }

    private func bumpOutbound() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        outboundSeq += 1
        return outboundSeq
    }

    // MARK: - 工具

    private func cidrHost(_ cidr: String) -> String {
        cidr.split(separator: "/").first.map(String.init) ?? cidr
    }

    private func cidrMask(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        let prefix = parts.count > 1 ? (Int(parts[1]) ?? 32) : 32
        let p = max(0, min(prefix, 32))
        let bits: UInt32 = p == 0 ? 0 : UInt32.max << (32 - p)
        return "\((bits >> 24) & 255).\((bits >> 16) & 255).\((bits >> 8) & 255).\(bits & 255)"
    }

    enum MergedError: LocalizedError {
        case noEngine
        var errorDescription: String? { "没有启用任何隧道功能" }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
