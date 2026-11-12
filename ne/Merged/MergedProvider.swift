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

        // 先把三份配置摊平，再让每个引擎「只算路由、不起数据面」。
        // 顺序很关键：PacketDispatcher 的分类表和 buildSettings() 读的就是
        // prepare 填进去的 routes / excludeRoutes / addresses / DNS。
        // 若等到 start() 才填，includedRoutes 会是空数组，而 macOS 把
        // 「空 includedRoutes」当成「接管全部 IPv4 流量」，会装上默认路由，
        // 连 SDP 自己的网关地址（本该在 excludeRoutes 里）也一起吸进隧道，
        // 结果就是隧道显示已连接、三路流量全部出不去。
        var built: [String: [String: Any]] = [:]
        for name in ["sdp", "wg", "ts"] {
            built[name] = (cfg[name] as? [String: Any]) ?? [:]
        }
        let configs = built
        for engine in engineList {
            engine.prepare(config: configs[engine.name] ?? [:])
        }
        NSLog("[Merged] 路由规划 %@",
              engineList.map { "\($0.name)=\($0.routes.count)/排除\($0.excludeRoutes.count)" }
                  .joined(separator: " "))

        let d = PacketDispatcher(flow: packetFlow)
        // SDP 是规则兜底：未按任何前缀命中时交给它（未启用则为 nil，包直接丢弃）
        let fallback = engineList.first { $0.name == "sdp" }
        d.register(engineList, fallback: fallback)
        dispatcher = d

        // Tailscale 登录后才会拿到真实 100.x 地址，那时引擎会回调这里重建设置
        for engine in engineList {
            engine.setNetworkChangeHandler { [weak self] in
                self?.reapplySettings(configs: configs)
            }
        }

        // 必须先建立虚拟网卡，再启动引擎的读写循环
        let settings = d.buildSettings()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[Merged] 应用网络设置失败: %@", error.localizedDescription)
                completionHandler(error)
                return
            }
            d.start(configs: configs) { startError in
                if let startError = startError {
                    NSLog("[Merged] 引擎启动失败: %@", startError.localizedDescription)
                } else {
                    NSLog("[Merged] 全部引擎已就绪 %@",
                          engineList.map { "\($0.name)=\($0.routes.count)路由" }
                              .joined(separator: " "))
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

    // MARK: - 运行中重建设置

    /// 引擎报告的地址/路由变化（Tailscale 拿到真实 100.x 之后）→ 重新规划 + 重下发。
    /// 只更新网络设置，不重启引擎、不重建 flow。
    private func reapplySettings(configs: [String: [String: Any]]) {
        guard let d = dispatcher else { return }
        let list = engines
        for engine in list {
            engine.prepare(config: configs[engine.name] ?? [:])
        }
        let settings = d.buildSettings()
        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("[Merged] 更新网络设置失败: %@", error.localizedDescription)
            } else {
                NSLog("[Merged] 网络设置已更新 %@",
                      list.map { "\($0.name)=\($0.addresses.count)地址/\($0.routes.count)路由" }
                          .joined(separator: " "))
            }
        }
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
