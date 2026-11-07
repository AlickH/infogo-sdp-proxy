import Foundation
import NetworkExtension
import Network

/// WireGuard Packet Tunnel 系统扩展
final class WGProvider: NEPacketTunnelProvider {
    private var adapter: WireGuardAdapter?

    override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let cfg = proto.providerConfiguration,
              let privateKeyStr = cfg["privateKey"] as? String,
              let privateKey = PrivateKey(base64Key: privateKeyStr),
              let peerKeyStr = cfg["peerPublicKey"] as? String,
              let peerPublicKey = PublicKey(base64Key: peerKeyStr) else {
            completionHandler(WGError.invalidConfig)
            return
        }

        var iface = InterfaceConfiguration(privateKey: privateKey)
        if let addrs = cfg["addresses"] as? [String] {
            iface.addresses = addrs.compactMap { IPAddressRange(from: $0) }
        }
        if let dns = cfg["dns"] as? [String] {
            iface.dns = dns.compactMap { str -> DNSServer? in
                if let addr = IPv4Address(str) { return DNSServer(address: addr) }
                if let addr = IPv6Address(str) { return DNSServer(address: addr) }
                return nil
            }
        }
        if let mtu = cfg["mtu"] as? Int, let m = UInt16(exactly: mtu) { iface.mtu = m }

        var peer = PeerConfiguration(publicKey: peerPublicKey)
        if let allowed = cfg["allowedIPs"] as? [String] {
            peer.allowedIPs = allowed.compactMap { IPAddressRange(from: $0) }
        }
        if let endpointStr = cfg["endpoint"] as? String {
            peer.endpoint = Endpoint(from: endpointStr)
        }
        if let keepalive = cfg["persistentKeepalive"] as? Int, let k = UInt16(exactly: keepalive), k > 0 {
            peer.persistentKeepAlive = k
        }

        let tunnel = TunnelConfiguration(name: "SDP WireGuard", interface: iface, peers: [peer])
        let adapter = WireGuardAdapter(with: self) { level, message in
            NSLog("[WG] %@", message)
            _ = level
        }
        self.adapter = adapter
        adapter.start(tunnelConfiguration: tunnel) { error in
            if let error = error {
                NSLog("[WG] 启动失败: %@", String(describing: error))
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter?.stop { _ in
            completionHandler()
        }
        adapter = nil
    }

    private enum WGError: Error { case invalidConfig }
}

