import Foundation
import NetworkExtension
import Tsbridge

/// 合并模式下的 WireGuard 引擎。
///
/// 逻辑来自合并前 WGNE 的 `WGProvider`（该文件已随合并删除），但去掉了 `setTunnelNetworkSettings`
/// 和 `packetFlow` 的持有——这两件事在合并后由 `PacketDispatcher` 统一负责，
/// 这里只保留「吃裸包 / 吐裸包」。
final class WGEngine: TunnelEngine {
    let name = "wg"

    private(set) var routes: [String] = []
    /// WireGuard 自己的内网地址（协议层面必须，用于对端回包匹配），
    /// 但不挂到 utun 上：那是协议内部的标识，内核不需要知道。
    private(set) var localAddresses: [String] = []

    /// **WG 的地址必须挂到 utun 上。**
    ///
    /// 三层隧道的回包（NAS → 我们）目的地址就是 10.0.0.3。若这个地址不在
    /// 本机任何接口上，内核收到回包后无法投递给应用，只能按路由又送回 utun10，
    /// 于是包再次进入分类器、再交给 WG 引擎，形成死循环（日志里成片的
    /// `10.0.0.2 -> 10.0.0.3 -> wg` 就是这个）。
    ///
    /// 同时出去的包源地址也必须改写成 10.0.0.3（见 tunnelSourceAddress）：
    /// 否则 NAS 按源 198.19.0.1 回包，而它那边没有这个地址，根本不会回。
    var addresses: [String] { localAddresses }

    /// 三层隧道：对端按明文包的源 IP 回包，所以必须把它改写成 10.0.0.3。
    /// 实时读取 localAddresses（配置里是 10.0.0.3/32）。
    var tunnelSourceAddress: String? {
        guard let cidr = localAddresses.first(where: { !$0.contains(":") }) else { return nil }
        return cidr.split(separator: "/").first.map(String.init) ?? cidr
    }
    private(set) var dnsServers: [String] = []
    let dnsMatchDomain = ""
    private(set) var mtu = 1280

    /// WG 的 endpoint（加密 UDP 的收发对端）必须排除出隧道
    private(set) var outboundTargets: [String] = []

    private var outbound: ((Data) -> Void)?
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); defer { lock.unlock() }; _stopped = newValue }
    }

    /// 只算路由 / 地址 / DNS / MTU，供 dispatcher 在建设置前调用。
    func prepare(config: [String: Any]) {
        routes = (config["allowedIPs"] as? [String]) ?? []
        let addrs = (config["addresses"] as? [String]) ?? []
        localAddresses = addrs
        dnsServers = (config["dns"] as? [String]) ?? []
        if let m = config["mtu"] as? Int, m >= 576 { mtu = m }
        let ep = (config["endpoint"] as? String) ?? ""
        outboundTargets = ep.isEmpty ? [] : [ep]
    }

    func start(config: [String: Any], completion: @escaping (Error?) -> Void) {
        prepare(config: config)
        guard let privateKeyB64 = config["privateKey"] as? String,
              let peerKeyB64 = config["peerPublicKey"] as? String,
              let privateHex = Self.hex(fromBase64: privateKeyB64),
              let peerHex = Self.hex(fromBase64: peerKeyB64) else {
            completion(WGEngineError.invalidConfig)
            return
        }

        let allowed = routes
        let endpoint = (config["endpoint"] as? String) ?? ""
        let keepalive = (config["persistentKeepalive"] as? Int) ?? 25

        // UAPI：密钥 hex；**不能有空行**（IpcSetOperation 把空行当终止解析）；
        // endpoint 域名由 Tsbridge 的 wgResolveEndpoints 负责解析成 IP。
        var uapi = "private_key=\(privateHex)\nlisten_port=0\n"
        uapi += "public_key=\(peerHex)\n"
        for cidr in allowed { uapi += "allowed_ip=\(cidr)\n" }
        if !endpoint.isEmpty { uapi += "endpoint=\(endpoint)\n" }
        if keepalive > 0 { uapi += "persistent_keepalive_interval=\(keepalive)\n" }

        var startErr: NSError?
        guard TsbridgeWgStart(uapi, &startErr) else {
            completion(startErr ?? WGEngineError.invalidConfig)
            return
        }

        // Go → OS：阻塞取已解密的包。
        //
        // 拿不到包时**不能直接退出循环**：`readOutbound` 在设备关闭时返回 nil，
        // 但引擎重启/设备重建期间也可能短暂返回 nil。一旦 break，这个读循环
        // 就永久结束，之后 wireguard-go 解密出来的所有包都不会再写回内核——
        // 现象是「加密包收发都正常、握手也成功，但内网就是不通」。
        // 只有 self.stopped 才是退出条件，其余情况继续等待。
        Diag.log("wg", "启动出向读循环 outbound已注册=\(self.outbound != nil)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                Diag.log("wg", "读循环启动失败：self 已释放")
                return
            }
            Diag.log("wg", "读循环开始运行")
            var got = 0
            while !self.stopped {
                guard let pkt = TsbridgeWgReadOutboundPacket() else {
                    if self.stopped { break }
                    Diag.log("wg", "readOutbound 返回 nil（未停止），继续等待")
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                let bytes = pkt as Data
                guard !bytes.isEmpty else { continue }
                got += 1
                if got <= 5 || got % 50 == 0 {
                    Diag.log("wg", "读到解密包 #\(got) \(bytes.count)B 回调=\(self.outbound != nil)")
                }
                self.outbound?(bytes)
            }
            Diag.log("wg", "出向读循环结束 stopped=\(self.stopped)")
        }
        Diag.log("wg", "started endpoint=\(endpoint) allowed=\(allowed.count) keepalive=\(keepalive)")
        completion(nil)
    }

    /// 把 wireguard-go 的运行时配置（UAPI）里的关键指标打进诊断日志。
    /// `last_handshake_time_sec=0` 说明握手从未成功；`rx_bytes` 一直是 0
    /// 说明对端的加密包一个都没收到（多半是 endpoint 的出向/回向被路由劫走）。
    func logStatus(_ reason: String) {
        let uapi = TsbridgeWgStatus()
        guard !uapi.isEmpty else {
            Diag.log("wg", "status(\(reason)) 设备未启动")
            return
        }
        var handshake = 0
        var rx = 0, tx = 0
        var endpoint = ""
        // 按 "key=" 的实际长度切，而不是硬编码数字：
        // 之前把 last_handshake_time_sec= 的 24 个字符写成 22，取到 "c="，
        // Int("c=") ?? 0 永远是 0，于是把「握手正常」误判成「从未握手成功」。
        func value(_ line: Substring, key: String) -> String? {
            guard line.hasPrefix(key + "=") else { return nil }
            return String(line.dropFirst(key.count + 1))
        }
        for line in uapi.split(separator: "\n") {
            if let v = value(line, key: "last_handshake_time_sec") { handshake = Int(v) ?? 0 }
            else if let v = value(line, key: "rx_bytes") { rx = Int(v) ?? 0 }
            else if let v = value(line, key: "tx_bytes") { tx = Int(v) ?? 0 }
            else if let v = value(line, key: "endpoint") { endpoint = v }
        }
        // 握手是否仍然有效，才是「隧道能不能用」的唯一判据。
        // tx 涨而 rx 不涨 = 对端收不到或回不来；握手不刷新 = 会话已过期。
        let age = handshake == 0 ? -1 : Int(Date().timeIntervalSince1970) - handshake
        let state: String
        if handshake == 0 {
            state = "从未握手成功"
        } else if age > 180 {
            state = "握手过期 \(age)s（会话已失效）"
        } else {
            state = "握手有效 \(age)s 前"
        }
        Diag.log("wg", "\(state) endpoint=\(endpoint) rx=\(rx) tx=\(tx)")

        // wireguard-go 自己的日志（握手失败原因、解密错误等）原本只写 stderr，
        // 在 NE 环境里完全不可见——这正是之前「看不出隧道内部怎么处理流量」的原因。
        // 现在从桥接层取出来落到诊断文件。
        // 解密产出计数：区分「对端没回包」和「回了但没写回系统」。
        Diag.log("wg", "解密产出=\(TsbridgeWgDecryptedCount()) 队列丢弃=\(TsbridgeWgDroppedCount())")

        let drained = TsbridgeWgDrainLog()
        guard !drained.isEmpty else { return }
        for line in drained.split(separator: "\n") {
            Diag.log("wg-go", String(line))
        }
    }

    func stop() {
        stopped = true
        var err: NSError?
        if !TsbridgeWgStop(&err) {
            Diag.log("wg", "stop 失败: \(err?.localizedDescription ?? "unknown")")
        }
    }

    func deliver(_ packet: Data) {
        var err: NSError?
        let ok = TsbridgeWgDeliverInboundPacket(packet, &err)
        let seq = bumpDeliver()
        if seq <= 12 || seq % 200 == 0 {
            Diag.log("wg", "deliver #\(seq) \(packet.count)B \(ok ? "ok" : "FAIL \(err?.localizedDescription ?? "")")")
        }
    }

    private let seqLock = NSLock()
    private var deliverSeq = 0
    private func bumpDeliver() -> Int {
        seqLock.lock(); defer { seqLock.unlock() }
        deliverSeq += 1
        return deliverSeq
    }

    func onOutbound(_ handler: @escaping (Data) -> Void) { outbound = handler }

    func handleMessage(_ message: Data, completion: @escaping (Data?) -> Void) {
        // App 侧解析 last_handshake_time_sec / rx_bytes / tx_bytes 的格式不变
        completion(TsbridgeWgStatus().data(using: .utf8))
    }

    private static func hex(fromBase64 s: String) -> String? {
        guard let d = Data(base64Encoded: s), d.count == 32 else { return nil }
        return d.map { String(format: "%02x", $0) }.joined()
    }

    enum WGEngineError: LocalizedError {
        case invalidConfig
        var errorDescription: String? { "WireGuard 配置缺私钥或对端公钥" }
    }
}
