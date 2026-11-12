import Foundation
import NetworkExtension
import Network
import Wgbridge

/// WireGuard Packet Tunnel 系统扩展（wgbridge 版）
///
/// 与旧实现的区别：
/// - 旧版用 `WireGuardAdapter`，它内部调用 `wgTurnOn(settings, tun_fd)`，
///   只接受**真实 utun 文件描述符**（甚至是靠扫描 fd 0~1024 找 utun 控制 socket 定位的），
///   所以 WireGuard 只能独占一条自己的隧道。
/// - 现在改用 `wgbridge` 提供的内存 `tun.Device`，包由我们自己在
///   `NEPacketTunnelFlow` 和 wireguard-go 之间搬运。这样 WireGuard 才能和
///   SDP / Tailscale 并进同一个扩展、共用一条 packet flow。
///
/// 配置（providerConfiguration）沿用原格式，字段含义不变。
final class WGProvider: NEPacketTunnelProvider {
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); defer { lock.unlock() }; _stopped = newValue }
    }

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let cfg = proto.providerConfiguration,
              let privateKeyB64 = cfg["privateKey"] as? String,
              let peerKeyB64 = cfg["peerPublicKey"] as? String,
              let privateKeyHex = Self.hex(fromBase64: privateKeyB64),
              let peerKeyHex = Self.hex(fromBase64: peerKeyB64) else {
            completionHandler(WGError.invalidConfig)
            return
        }

        let addresses = (cfg["addresses"] as? [String]) ?? []
        let dns = (cfg["dns"] as? [String]) ?? []
        let allowedIPs = (cfg["allowedIPs"] as? [String]) ?? []
        let endpoint = (cfg["endpoint"] as? String) ?? ""
        let keepalive = (cfg["persistentKeepalive"] as? Int) ?? 25
        let mtu = (cfg["mtu"] as? Int) ?? 1420

        // UAPI 格式；注意密钥是 hex，不是配置里的 base64。
        // 关键：**不能有空行**——wireguard-go 的 IpcSetOperation 把空行当作
        // 「终止解析」（uapi.go:158），写了空行后面所有 peer 配置都会被忽略。
        // public_key= 这一行本身就会把解析器从设备配置切到 peer 配置。
        var uapi = "private_key=\(privateKeyHex)\nlisten_port=0\n"
        uapi += "public_key=\(peerKeyHex)\n"
        for cidr in allowedIPs { uapi += "allowed_ip=\(cidr)\n" }
        if !endpoint.isEmpty { uapi += "endpoint=\(endpoint)\n" }
        if keepalive > 0 { uapi += "persistent_keepalive_interval=\(keepalive)\n" }

        var startErr: NSError?
        guard WgbridgeStart(uapi, &startErr) else {
            NSLog("[WG] wgbridge 启动失败: %@", startErr?.localizedDescription ?? "unknown")
            completionHandler(startErr ?? WGError.invalidConfig)
            return
        }
        NSLog("[WG] wgbridge 已启动 v%@ allowedIPs=%@ endpoint=%@",
              WgbridgeVersion(), allowedIPs.joined(separator: ","), endpoint)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: max(576, min(mtu, 65535)))

        let v4 = addresses.filter { !$0.contains(":") }
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4.map(Self.host),
                                      subnetMasks: v4.map(Self.mask))
            var routes: [NEIPv4Route] = []
            for cidr in allowedIPs where !cidr.contains(":") {
                routes.append(NEIPv4Route(destinationAddress: Self.host(cidr),
                                          subnetMask: Self.mask(cidr)))
            }
            ipv4.includedRoutes = routes
            settings.ipv4Settings = ipv4
        }
        if !dns.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dns)
        }

        // 必须等 setTunnelNetworkSettings 完成后再搬包，否则虚拟网卡尚未建立
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self, error == nil else {
                NSLog("[WG] 应用网络设置失败: %@", error?.localizedDescription ?? "unknown")
                completionHandler(error)
                return
            }
            self.startPacketLoops()
            completionHandler(nil)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        // 返回 UAPI 文本，App 侧解析 last_handshake_time_sec / rx_bytes / tx_bytes
        completionHandler?(WgbridgeStatus().data(using: .utf8))
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopped = true
        var err: NSError?
        if !WgbridgeStop(&err) {
            NSLog("[WG] wgbridge 停止失败: %@", err?.localizedDescription ?? "unknown")
        }
        completionHandler()
    }

    // MARK: - 数据面

    private func startPacketLoops() {
        // OS → Go：读虚拟网卡的包交给 wireguard-go 加密
        func pump() {
            packetFlow.readPackets { [weak self] packets, _ in
                guard let self = self, !self.stopped else { return }
                for p in packets {
                    var err: NSError?
                    if !WgbridgeDeliverInboundPacket(p, &err) {
                        NSLog("[WG] inbound 丢包: %@", err?.localizedDescription ?? "closed")
                    }
                }
                if !self.stopped { pump() }
            }
        }
        pump()

        // Go → OS：阻塞取已解密的包写回虚拟网卡
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while !self.stopped {
                guard let pkt = WgbridgeReadOutboundPacket() else { break }
                let bytes = pkt as Data
                guard !bytes.isEmpty else { continue }
                // 裸 IP 包首字节高 4 位：4 = IPv4, 6 = IPv6
                let version = (bytes.first ?? 0) >> 4
                let af: NSNumber = version == 6 ? 30 : 2
                self.packetFlow.writePackets([bytes], withProtocols: [af])
            }
        }
    }

    // MARK: - 工具

    /// base64 密钥 → UAPI 需要的 hex
    private static func hex(fromBase64 s: String) -> String? {
        guard let d = Data(base64Encoded: s), d.count == 32 else { return nil }
        return d.map { String(format: "%02x", $0) }.joined()
    }

    /// "10.0.0.3/32" → "10.0.0.3"
    private static func host(_ cidr: String) -> String {
        cidr.split(separator: "/").first.map(String.init) ?? cidr
    }

    /// "10.0.0.0/24" → "255.255.255.0"
    private static func mask(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        let prefix = parts.count > 1 ? (Int(parts[1]) ?? 32) : 32
        let p = max(0, min(prefix, 32))
        let bits: UInt32 = p == 0 ? 0 : UInt32.max << (32 - p)
        return "\((bits >> 24) & 255).\((bits >> 16) & 255).\((bits >> 8) & 255).\(bits & 255)"
    }

    private enum WGError: Error { case invalidConfig }
}
