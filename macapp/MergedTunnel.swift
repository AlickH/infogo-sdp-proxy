import Foundation
import NetworkExtension

/// 合并后的唯一 VPN 配置持有者。
///
/// 三个 UI 开关（SDP 代理 / WireGuard / Tailscale）在旧架构里各建一条 VPN；
/// 合并后它们只是 `features` 里的三个布尔位，共用同一条隧道、同一个
/// `NETunnelProviderManager`。三个 Manager 类保留为门面，负责自己的配置与状态解析，
/// 但 providerConfiguration 一律从这里生成。
///
/// 状态持久化到 UserDefaults：App 每次启动都是新进程，而三个 Manager 的
/// `autoStartIfConfigured()` 调用顺序不定，不能让先跑的那个把 features 覆盖成只有自己。
/// `_features` / `_configs` 全部由 NSLock 保护，`UserDefaults` 本身线程安全，
/// 因此 `@unchecked Sendable` 成立（Swift 6 严格并发要求静态单例可发送）。
final class MergedTunnel: @unchecked Sendable {
    static let shared = MergedTunnel()
    /// 复用原 SDPNE 的 bundle ID —— 这样不需要新的 App ID / provisioning profile
    static let extensionID = "com.alick.sdp-proxy.ne"

    private static let featuresKey = "sdp.merged.features"
    private static let configsKey = "sdp.merged.configs"

    private let lock = NSLock()
    private var _features: Set<String>
    private var _configs: [String: [String: Any]]

    private init() {
        let d = UserDefaults.standard
        _features = Set(d.stringArray(forKey: Self.featuresKey) ?? [])
        _configs = (d.dictionary(forKey: Self.configsKey) as? [String: [String: Any]]) ?? [:]
    }

    private func persistLocked() {
        let d = UserDefaults.standard
        d.set(_features.sorted(), forKey: Self.featuresKey)
        d.set(_configs, forKey: Self.configsKey)
    }

    /// 开关某个功能；传 config 时同时更新该功能自己的配置
    func set(_ name: String, enabled: Bool, config: [String: Any]? = nil) {
        lock.lock(); defer { lock.unlock() }
        if enabled {
            _features.insert(name)
            if let config { _configs[name] = config }
        } else {
            _features.remove(name)
        }
        persistLocked()
    }

    var features: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return _features
    }

    /// UI 开关的唯一真相：合并后三个 Manager 共用一条 VPN，
    /// 不能拿「隧道已连接」当成「本功能已启用」。
    func isEnabled(_ name: String) -> Bool { features.contains(name) }

    var isEmpty: Bool { features.isEmpty }

    /// 生成扩展侧 MergedProvider 需要的配置
    func providerConfiguration() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "features": _features.sorted(),
            "sdp": _configs["sdp"] ?? [:],
            "wg": _configs["wg"] ?? [:],
            "ts": _configs["ts"] ?? [:],
        ]
    }

    /// 迁移：删掉旧架构里 .wg / .ts 两条 VPN 配置。
    /// 合并后它们的扩展二进制已不在 App 里，留着会和新隧道抢路由、且永远连不上。
    static func cleanupLegacyConfigs(completion: @escaping @MainActor () -> Void) {
        let legacy: Set<String> = ["com.alick.sdp-proxy.wg", "com.alick.sdp-proxy.ts"]
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let doomed = (managers ?? []).filter {
                guard let bid = ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                else { return false }
                return legacy.contains(bid)
            }
            let group = DispatchGroup()
            for m in doomed {
                group.enter()
                m.connection.stopVPNTunnel()
                m.removeFromPreferences { _ in group.leave() }
            }
            group.notify(queue: .main) {
                NSLog("[Merged] 已清理 %d 条旧 VPN 配置", doomed.count)
                Task { @MainActor in completion() }
            }
        }
    }

    /// 把三个 Manager 各自的状态轮询消息路由到对应引擎。
    /// MergedProvider 的 PacketDispatcher 按 `name:` 前缀分发。
    static func command(_ engine: String, _ body: String = "status") -> Data {
        Data("\(engine):\(body)".utf8)
    }
}
