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

    /// 透传型引擎当前的地址（引擎名 → 点分十进制）。
    ///
    /// **不能缓存**：Tailscale 启动时只有占位地址 100.64.0.254，登录后才换成真实的
    /// 100.x。若在 register() 时求值一次，之后所有回包的源地址都会被改写成那个
    /// 已经不存在的占位地址，内核直接丢弃——表现为「隧道连着、status 显示 Running、
    /// 但内网一个包都通不了」。所以每次改写都读引擎的实时 addresses。

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

    /// 各引擎最近一次出向时，**内核实际选择**的源地址（如 198.19.0.1）。
    ///
    /// 回向必须还原成它，而不是引擎的隧道地址：内核只认得自己当初写进
    /// 连接的那个地址，还原成别的值会被判定为「不属于任何连接」并回 RST。
    private var kernelSources: [String: String] = [:]

    private func setKernelSource(_ engine: String, _ addr: String) {
        lock.lock(); defer { lock.unlock() }
        kernelSources[engine] = addr
    }

    private func kernelSource(for engine: String) -> String? {
        lock.withLock { kernelSources[engine] }
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
                // 引擎 → OS：把 NAT 过的目的地址还原成内核认得的隧道地址
                let restored: Data
                if let kernelSrc = self.kernelSource(for: name) {
                    restored = SourceRewriter.rewrite(packet, destination: kernelSrc) ?? packet
                } else {
                    restored = packet
                }
                let version = (restored.first ?? 0) >> 4
                let af: NSNumber = version == 6 ? 30 : 2
                // writePackets 会返回 false 表示写回被拒（包被静默丢弃）。
                // 不检查返回值的话，引擎明明产出了包、系统却一个都没收到，
                // 而日志上看起来一切正常。
                let ok = self.flow.writePackets([restored], withProtocols: [af])
                if !ok {
                    Diag.log("outbound", "FAIL #\(seq) \(name) \(restored.count)B 写回被拒")
                }
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
                // 采样会掩盖问题：把改写前后的源地址都记下来，
                // 并让 wg/ts 的包始终可见（它们的量小，正是排查重点）。
                if seq <= 12 || seq % 200 == 0 || engine?.name != "sdp" {
                    let src = IPPrefix.source(of: packet).map(IPPrefix.string) ?? "?"
                    Diag.log("pump", "#\(seq) \(src) -> \(IPPrefix.string(dst)) \(packet.count)B -> \(engine?.name ?? "无引擎,丢弃")")
                }
                guard let engine else { continue }
                // 不做源地址改写。
                //
                // 单 utun 上只保留隧道自己的地址（SDP 的 198.19.0.1），内核选源
                // 没有别的候选，天然一致；WG/TS 的真实地址由各自引擎在用户态
                // 使用，不需要内核知道。回包写回 flow 时目的地址正是内核当初
                // 三层隧道（WG）做双向地址转换，详见 SourceRewriter 的说明：
                //   OS → 引擎：源 198.19.0.1 → 10.0.0.3（对端才认）
                //   引擎 → OS：目的 10.0.0.3 → 198.19.0.1（内核才认，否则回 RST）
                // 终结型引擎（SDP/TS）不改，它们在用户态重建连接，源地址不参与决策。
                if let tunnelAddr = engine.tunnelSourceAddress {
                    if let kernelSrc = IPPrefix.source(of: packet).map(IPPrefix.string) {
                        setKernelSource(engine.name, kernelSrc)
                    }
                    if let fixed = SourceRewriter.rewrite(packet, source: tunnelAddr) {
                        engine.deliver(fixed)
                    } else {
                        engine.deliver(packet)
                    }
                } else {
                    engine.deliver(packet)
                }
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
