import Foundation
import NetworkExtension
import SystemExtensions
import Combine

/// 系统扩展（透明代理）管理：安装 → 配置 → 启动
/// `@unchecked Sendable`：NE 的 @Sendable 回调需要捕获 self；本类状态仅在主队列读写。
final class NEManager: NSObject, ObservableObject, @unchecked Sendable {
    static let extensionID = MergedTunnel.extensionID

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var lastError = ""

    private var manager: NETunnelProviderManager?
    private var pendingConfig: [String: Any] = [:]
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false
    private var configuring = false

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            // 只关心本 App 的透明代理连接，忽略 Surge/Amnezia 等其他 NE 的状态变化
            guard let conn = note.object as? NEVPNConnection, conn === self.manager?.connection else { return }
            self.scheduleRefresh()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 开关

    func enable(config: [String: Any]) {
        self.pendingConfig = config
        MergedTunnel.shared.set("sdp", enabled: true, config: config)
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        // 合并后不能 stop 整条隧道——其它功能可能还在用。
        // 只把本功能从 features 里摘掉并重新下发配置。
        MergedTunnel.shared.set("sdp", enabled: false)
        if MergedTunnel.shared.isEmpty {
            manager?.connection.stopVPNTunnel()
        } else {
            configureAndStart()
        }
        statusText = "已关闭"
        active = false
    }

    /// 停止并禁用已保存的透明代理配置（用于紧急恢复网络）
    func disableAndRemoveConfig(completion: @escaping () -> Void = {}) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { completion(); return }
            let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
            })
            mgr?.connection.stopVPNTunnel()
            mgr?.isEnabled = false
            mgr?.saveToPreferences { _ in
                // Swift 6：completion 非 Sendable，显式放行（仅在主队列回调）
                nonisolated(unsafe) let done = completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.statusText = "已禁用"
                    self.active = false
                    done()
                }
            }
            if mgr == nil { completion() }
        }
    }

    /// 已保存过配置时，App 启动后自动恢复透明代理
    func autoStartIfConfigured() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self,
                  let mgr = managers?.first(where: {
                      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
                  }) else { return }
            self.manager = mgr
            if mgr.isEnabled, mgr.connection.status == .disconnected {
                try? mgr.connection.startVPNTunnel()
            }
            self.refreshStatus()
        }
    }

    // MARK: - 状态

    private func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        // Swift 6：@Sendable 闭包不能直接捕获非 Sendable 的 self，这里保留弱引用语义
        nonisolated(unsafe) weak var me = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            me?.refreshScheduled = false
            me?.refreshStatus()
        }
    }

    func refreshStatus() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                return
            }
            guard let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
            }) else {
                self.statusText = "未启用"
                self.active = false
                return
            }
            self.manager = mgr
            switch mgr.connection.status {
            case .connected:
                self.statusText = "全局接管中"
                self.active = true
            case .connecting, .reasserting:
                self.statusText = "正在启动…"
                self.active = true
            case .disconnecting:
                self.statusText = "正在停止…"
                self.active = false
            case .disconnected, .invalid:
                self.statusText = "已关闭"
                self.active = false
            @unknown default:
                self.statusText = "未知状态"
                self.active = false
            }
        }
    }

    func configureAndStart() {
        if configuring { return }
        // 合并后任何功能启用时都需要重配并重发配置；SDP 的 config 已由 enable(config:)
        // 写入 shared，不依赖实例变量 pendingConfig，否则 App 重启后 disable 重配会被
        // 门槛挡住、SDP 实际关不掉。
        guard !MergedTunnel.shared.features.isEmpty else {
            statusText = "无启用的功能"
            return
        }
        configuring = true
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            defer { self.configuring = false }
            if let error = error {
                self.lastError = error.localizedDescription
                self.statusText = "配置读取失败"
                return
            }
            let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
            }) ?? NETunnelProviderManager()
            self.manager = mgr
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = "127.0.0.1"
            proto.providerConfiguration = MergedTunnel.shared.providerConfiguration()
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP"
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                if let error = error {
                    self.lastError = error.localizedDescription
                    self.statusText = "配置保存失败"
                    return
                }
                mgr.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        self.lastError = loadError.localizedDescription
                        self.statusText = "配置重载失败"
                        return
                    }
                    // 配置变化后必须重启隧道，否则仍在用旧配置
                    if mgr.connection.status == .connected || mgr.connection.status == .connecting {
                        mgr.connection.stopVPNTunnel()
                        // Swift 6：manager 非 Sendable，显式放行跨闭包传递
                        nonisolated(unsafe) let manager = mgr
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            do { try manager.connection.startVPNTunnel(); self.statusText = "正在启动…" }
                            catch { self.lastError = error.localizedDescription; self.statusText = "启动失败" }
                        }
                    } else {
                        do {
                            try mgr.connection.startVPNTunnel()
                            self.statusText = "正在启动…"
                        } catch {
                            self.lastError = error.localizedDescription
                            self.statusText = "启动失败"
                        }
                    }
                    self.refreshStatus()
                }
            }
        }
    }
}

extension NEManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusText = "等待系统批准扩展…"
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            statusText = "扩展已安装"
            configureAndStart()
        case .willCompleteAfterReboot:
            statusText = "需要重启后生效"
        @unknown default:
            statusText = "扩展安装完成"
            configureAndStart()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        lastError = error.localizedDescription
        statusText = "扩展安装失败"
    }
}
