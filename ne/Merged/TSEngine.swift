import Foundation
import NetworkExtension
import Tsbridge

/// 合并模式下的 Tailscale 引擎。
///
/// 复用 `TSBridgeRuntime`（状态目录、占位隧道、MagicDNS、status 都在里面），
/// 但用 `ownsFlow: false` 让它不自己驱动 packetFlow，改由 `PacketDispatcher` 搬运。
///
/// 与独立扩展模式的一处简化：合并后隧道已经因为其它功能而存在，
/// 因此不再需要「先建占位隧道再升级真实地址」；状态目录里已有登录态，
/// `addresses` 直接从 TsbridgeStatus() 读真实 100.x 地址。
final class TSEngine: TunnelEngine {
    let name = "ts"

    private(set) var routes: [String] = []
    private(set) var addresses: [String] = []
    private(set) var dnsServers: [String] = []
    private(set) var dnsMatchDomain = ""
    private(set) var mtu = 1280

    private let runtime: TSBridgeRuntime
    private var outbound: ((Data) -> Void)?

    /// 合并后由 dispatcher 统一管网络设置，这里不需要真的下发；
    /// 但 TSBridgeRuntime 内部会用这个回调判断「设置是否应用成功」，必须回 nil。
    private var noopApply: (NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void {
        { _, done in done(nil) }
    }

    init(packetFlow: NEPacketTunnelFlow) {
        self.runtime = TSBridgeRuntime(packetFlow: packetFlow, ownsFlow: false)
    }

    func start(config: [String: Any], completion: @escaping (Error?) -> Void) {
        let status = Self.statusDict()
        let ips = (status["selfIPs"] as? [String])?.filter { !$0.contains(":") } ?? []
        let suffix = (status["tailnet"] as? String) ?? ""
        let acceptDNS = config["acceptDNS"] as? Bool ?? true

        routes = (config["routes"] as? [String])?.filter { !$0.isEmpty } ?? ["100.64.0.0/10"]
        addresses = ips.isEmpty ? ["100.64.0.254/32"] : ips.map { $0 + "/32" }
        dnsServers = acceptDNS ? ["100.100.100.100"] : []
        dnsMatchDomain = suffix
        mtu = (config["mtu"] as? Int) ?? 1280

        runtime.setOutboundHandler { [weak self] packet in self?.outbound?(packet) }
        runtime.start(configuration: config, applySettings: noopApply, completion: completion)
    }

    func stop() { runtime.stop {} }

    func deliver(_ packet: Data) { runtime.deliver(packet) }

    func onOutbound(_ handler: @escaping (Data) -> Void) { outbound = handler }

    func handleMessage(_ message: Data, completion: @escaping (Data?) -> Void) {
        let cmd = String(data: message, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch cmd {
        case "status": completion(runtime.statusJSON())
        case "logout": runtime.logout(); completion(Data("ok".utf8))
        case "login": runtime.loginInteractive(); completion(Data("ok".utf8))
        case "ping": completion(Data("pong".utf8))
        default: completion(nil)
        }
    }

    private static func statusDict() -> [String: Any] {
        guard let data = TsbridgeStatus().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}
