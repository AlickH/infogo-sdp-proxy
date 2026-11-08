import Foundation
import NetworkExtension
import Network

/// Packet Tunnel 系统扩展（TUN 模式）
/// 第一阶段：建立 TUN 并下发路由（仅策略 IP 段），数据面后续接入
final class Provider: NEPacketTunnelProvider {
    private func dbg(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let path = "/tmp/sdpne.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        dbg("startTunnel called")
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let cfg = proto?.providerConfiguration ?? [:]
        let routes = (cfg["routes"] as? [String]) ?? []
        let dnsServers = (cfg["dns"] as? [String]) ?? []
        let mtu = (cfg["mtu"] as? Int).flatMap { NSNumber(value: $0) }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = mtu
        var ipv4 = NEIPv4Settings(addresses: ["198.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = routes.compactMap { Self.route(from: $0) }
        settings.ipv4Settings = ipv4
        if !dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        }
        dbg("routes=\(routes.joined(separator: ",")) dns=\(dnsServers) mtu=\(String(describing: mtu))")
        setTunnelNetworkSettings(settings) { error in
            self.dbg("setTunnelNetworkSettings error=\(String(describing: error))")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        dbg("stopTunnel reason=\(reason.rawValue)")
        completionHandler()
    }

    static func route(from cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let mask = prefix == 0 ? "0.0.0.0" : prefixSelfMask(prefix)
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: mask)
    }

    static func prefixSelfMask(_ prefix: Int) -> String {
        var bits: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        var parts: [String] = []
        for _ in 0..<4 {
            parts.append(String((bits >> 24) & 0xFF))
            bits <<= 8
        }
        return parts.joined(separator: ".")
    }
}
