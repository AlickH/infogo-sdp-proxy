import Foundation
import NetworkExtension
import Combine

/// 合并后的 **VPN 总开关**。
///
/// 三隧道合并后只有一条 `NETunnelProviderManager`，所以「连不连网」必须是
/// 一个独立开关；三个页面里的开关只决定「本功能是否参与这条隧道」
/// （`MergedTunnel.features`），不再负责启动/停止 VPN。
///
/// - 总开关开：保存 providerConfiguration → 建立隧道（app extension 由系统按需加载，
///   **不需要** OSSystemExtensionRequest 激活，也不需要用户在系统设置里批准）
/// - 总开关关：只 stop 隧道，保留配置和三个功能的启用状态
/// - 功能开关变化：`applyFeatures()` 在隧道连着时热重连，没连时什么都不做
/// 所有可变状态（wanted / connected / statusText / manager）都在主队列上读写：
/// 偏好设置的回调统一 `DispatchQueue.main.async` 回抛，因此 @unchecked Sendable 成立。
final class MergedVPN: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = MergedVPN()

    static let extensionID = "com.alick.sdp-proxy.tunnel"
    private static let wantedKey = "sdp.merged.vpnWanted"

    /// 总开关状态（持久化，App 重启后据此自动恢复）
    @Published private(set) var wanted: Bool
    /// 隧道是否真的连上（NEVPNStatus）
    @Published private(set) var connected = false
    @Published private(set) var statusText = "未连接"

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    override init() {
        if UserDefaults.standard.object(forKey: Self.wantedKey) == nil {
            // 老版本没有总开关：隧道连着就视为「开」，避免升级后开关与现状不符
            wanted = true
        } else {
            wanted = UserDefaults.standard.bool(forKey: Self.wantedKey)
        }
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.syncStatus() }
        refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: - 对外

    /// App 启动时调用：总开关开着则恢复连接，关着则确保隧道确实停掉
    /// （VPN 连接会跨 App 重启保留，只刷新状态会留下「开关关、隧道却连着」）
    func restore() {
        wanted ? start() : stop()
    }

    func setWanted(_ value: Bool) {
        wanted = value
        UserDefaults.standard.set(value, forKey: Self.wantedKey)
        if value { start() } else { stop() }
    }

    /// 功能开关变化后调用：连着就重推配置，没连就等下次 start() 自然带上
    func applyFeatures() {
        guard wanted else { return }
        reload()
    }

    // MARK: - 连接管理

    // MARK: - 诊断

    private func note(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        let path = "/tmp/sdpvpn.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func start() {
        note("start() wanted=\(wanted)")
        reload()
    }

    private func stop() {
        note("stop() 总开关关闭")
        // 可能还没加载过 manager，先加载再停，避免漏掉已存在的连接
        refresh { mgr in mgr?.connection.stopVPNTunnel() }
        syncStatus()
        statusText = "已断开"
    }

    /// 把 MergedTunnel 里最新的 features + 三份配置写进 VPN 配置并启动/重启隧道
    private func reload() {
        refresh { [weak self] existing in
            guard let self else { return }
            let mgr = existing ?? NETunnelProviderManager()
            let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
                ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = "SDP"
            proto.providerConfiguration = MergedTunnel.shared.providerConfiguration()
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP"
            mgr.isEnabled = true
            manager = mgr
            mgr.saveToPreferences { [weak self] error in
                guard let self else { return }
                if let error {
                    note("saveToPreferences 失败: \(error.localizedDescription)")
                    statusText = "配置保存失败：\(error.localizedDescription)"
                    return
                }
                note("配置已保存 features=\(MergedTunnel.shared.features.sorted())")
                mgr.loadFromPreferences { [weak self] loadError in
                    guard let self else { return }
                    if let loadError { note("loadFromPreferences 失败: \(loadError.localizedDescription)") }
                    self.connect(mgr)
                }
            }
        }
    }

    private func connect(_ mgr: NETunnelProviderManager) {
        let status = mgr.connection.status
        note("connect() status=\(status.rawValue) wanted=\(wanted) enabled=\(mgr.isEnabled)")
        if status == .connected || status == .connecting {
            // 隧道还连着：先停，等它**真的**进入 disconnected 再重启。
            //
            // 不能像以前那样固定等 0.8 秒——隧道拆除耗时不受控，提前 start
            // 会撞上 neagent 侧尚未释放的会话，报：
            //   NEAgentErrorDomain error 1
            //   "The connection to service ... was invalidated from this process"
            // 表现是 App 每次重启后隧道都连不上，必须手动等一会再点。
            mgr.connection.stopVPNTunnel()
            waitForDisconnectThenStart(attemptsLeft: 25)
        } else if wanted {
            do { try mgr.connection.startVPNTunnel(); note("启动成功") }
            catch { note("启动失败: \(error.localizedDescription)") }
        }
        statusText = "正在连接…"
        syncStatus()
    }

    /// 轮询等待连接进入 disconnected（每 0.2s，最多 attemptsLeft 次）后启动。
    /// 中断时只要 wanted 变成 false 就放弃，避免用户关掉开关后又被拉起。
    private func waitForDisconnectThenStart(attemptsLeft: Int) {
        guard wanted else { note("等待期间总开关已关闭，放弃启动"); return }
        // 统一用 self.manager，避免把非 Sendable 的 manager 跨闭包传递
        guard let mgr = manager else { note("等待时 manager 已释放"); return }
        let status = mgr.connection.status
        if status != .disconnecting && status != .connected && status != .connecting {
            do {
                try mgr.connection.startVPNTunnel()
                note("启动成功（已确认拆除，status=\(status.rawValue)）")
            } catch {
                note("启动失败: \(error.localizedDescription)")
            }
            return
        }
        guard attemptsLeft > 0 else {
            note("等待隧道拆除超时（status=\(status.rawValue)），放弃启动")
            statusText = "隧道未正常拆除，请重试"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForDisconnectThenStart(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func refresh(completion: ((NETunnelProviderManager?) -> Void)? = nil) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            let found = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == Self.extensionID
            }
            // Swift 6：NETunnelProviderManager 非 Sendable，显式放行跨闭包传递
            nonisolated(unsafe) let unsafeFound = found
            nonisolated(unsafe) let done = completion
            DispatchQueue.main.async {
                self?.manager = unsafeFound
                self?.syncStatus()
                done?(unsafeFound)
            }
        }
    }

    private func syncStatus() {
        let status = manager?.connection.status ?? .invalid
        let wasConnected = connected
        connected = status == .connected
        if wanted {
            switch status {
            case .connected: statusText = "已连接"
            case .connecting, .reasserting: statusText = "正在连接…"
            case .disconnecting: statusText = "正在断开…"
            case .disconnected, .invalid: statusText = "未连接"
            @unknown default: statusText = "未知"
            }
        }
        if wasConnected != connected {
            // 三个页面的状态文本也跟着刷新一次
            NotificationCenter.default.post(name: .mergedVPNStatusChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let mergedVPNStatusChanged = Notification.Name("sdp.mergedVPNStatusChanged")
}
