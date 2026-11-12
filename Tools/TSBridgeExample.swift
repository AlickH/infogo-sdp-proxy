import Foundation
import NetworkExtension

/// TS_BRIDGE_SRC 的最小模板 / 编译链路验证样例。
///
/// **这不是可用的 Tailscale 引擎**：`start` 会明确返回 `engineNotEmbedded`。
/// 真实适配层需要在这里接管 `packetFlow`、启动 tailscaled 控制面与数据面，
/// 并通过 `TSTunnelSettings.build` 下发路由/DNS（契约见 `ne/TSProvider.swift`）。
///
/// 用它验证构建链路：
/// ```bash
/// TS_BRIDGE_SRC=Tools/TSBridgeExample.swift ./scripts/build-tsne.sh
/// ```
/// 脚本会加 `-D TS_HAS_BRIDGE`，`TSBridgeSetup` 随即调用下面的注册函数。
final class ExampleRuntime: TailscaleRuntime {
    func start(configuration: [String: Any],
               applySettings: @escaping (NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void,
               completion: @escaping (Error?) -> Void) {
        _ = configuration
        _ = applySettings
        completion(TailscaleRuntimeError.engineNotEmbedded)
    }

    func statusJSON() -> Data? { nil }

    func logout() {}

    func stop(completion: @escaping () -> Void) { completion() }
}

/// `build-tsne.sh` 带 `-D TS_HAS_BRIDGE` 编译时，`TSBridgeSetup` 会调用此函数。
/// 函数名固定，构建方不要改名。
func registerTailscaleRuntimeBridge() {
    TailscaleRuntimeFactory.register { _ in ExampleRuntime() }
}
