import Foundation
import NetworkExtension

/// 合并后的唯一 Provider：一条 packet flow + 分类器 + 三个功能引擎。
///
/// 三个 UI 开关不再是「是否建立某条 VPN」，而是「是否启用某个功能」，
/// 通过 `providerConfiguration["features"]` 传进来。
/// 关闭某个功能只需改这个数组并保存配置，隧道本身不重建接口，
/// 只是少启动一个引擎、少声明一段路由。
final class MergedProvider: NEPacketTunnelProvider {
    private var dispatcher: PacketDispatcher?
    private var engines: [TunnelEngine] = []

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        let cfg = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let features = Set((cfg["features"] as? [String]) ?? ["sdp"])
        NSLog("[Merged] 启动功能: %@", features.sorted().joined(separator: ","))

        let engineList = buildEngines(features: features)
        guard !engineList.isEmpty else {
            completionHandler(MergedProviderError.noFeature)
            return
        }
        engines = engineList

        let d = PacketDispatcher(flow: packetFlow)
        // SDP 是规则兜底：未按任何前缀命中时交给它（未启用则为 nil，包直接丢弃）
        let fallback = engineList.first { $0.name == "sdp" }
        d.register(engineList, fallback: fallback)
        dispatcher = d

        // 必须先建立虚拟网卡，再启动引擎的读写循环
        let settings = d.buildSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[Merged] 应用网络设置失败: %@", error.localizedDescription)
                completionHandler(error)
                return
            }
            var configs: [String: [String: Any]] = [:]
            for name in ["sdp", "wg", "ts"] {
                configs[name] = (cfg[name] as? [String: Any]) ?? [:]
            }
            d.start(configs: configs) { startError in
                if let startError = startError {
                    NSLog("[Merged] 引擎启动失败: %@", startError.localizedDescription)
                } else {
                    NSLog("[Merged] 全部引擎已就绪 routes=%@",
                          engineList.flatMap(\.routes).joined(separator: ","))
                }
                completionHandler(startError)
            }
        }
    }

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)? = nil) {
        guard let d = dispatcher else { completionHandler?(nil); return }
        d.handleMessage(messageData) { reply in
            completionHandler?(reply)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        NSLog("[Merged] 停止 reason=%@", String(describing: reason))
        dispatcher?.stop()
        dispatcher = nil
        engines = []
        completionHandler()
    }

    // MARK: - 构建

    private func buildEngines(features: Set<String>) -> [TunnelEngine] {
        var list: [TunnelEngine] = []
        if features.contains("sdp") {
            list.append(SDPEngine())
        }
        if features.contains("wg") {
            list.append(WGEngine())
        }
        if features.contains("ts") {
            list.append(TSEngine(packetFlow: packetFlow))
        }
        return list
    }

    enum MergedProviderError: LocalizedError {
        case noFeature
        var errorDescription: String? { "至少启用一个功能（SDP / WireGuard / Tailscale）" }
    }
}
