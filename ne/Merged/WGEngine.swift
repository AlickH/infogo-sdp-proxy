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
    private(set) var addresses: [String] = []
    private(set) var dnsServers: [String] = []
    let dnsMatchDomain = ""
    private(set) var mtu = 1280

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
        addresses = (config["addresses"] as? [String]) ?? []
        dnsServers = (config["dns"] as? [String]) ?? []
        if let m = config["mtu"] as? Int, m >= 576 { mtu = m }
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

        // Go → OS：阻塞取已解密的包
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while !self.stopped {
                guard let pkt = TsbridgeWgReadOutboundPacket() else { break }
                let bytes = pkt as Data
                guard !bytes.isEmpty else { continue }
                self.outbound?(bytes)
            }
        }
        completion(nil)
    }

    func stop() {
        stopped = true
        var err: NSError?
        if !TsbridgeWgStop(&err) {
            NSLog("[WG-Engine] stop 失败: %@", err?.localizedDescription ?? "unknown")
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
