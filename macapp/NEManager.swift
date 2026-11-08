import Foundation
import NetworkExtension
import SystemExtensions
import Combine

/// 系统扩展（透明代理）管理：安装 → 配置 → 启动
final class NEManager: NSObject, ObservableObject {
    static let extensionID = "com.alick.sdp-proxy.ne"

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var lastError = ""

    private var manager: NETunnelProviderManager?
    private var socksPort: UInt16 = 11095
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

    func enable(socksPort: UInt16) {
        self.socksPort = socksPort
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        manager?.connection.stopVPNTunnel()
        statusText = "已关闭"
        active = false
    }

    /// 停止并禁用已保存的透明代理配置（用于紧急恢复网络）
    func disableAndRemoveConfig(completion: @escaping () -> Void = {}) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { completion(); return }
            let mgr = managers?.first
            mgr?.connection.stopVPNTunnel()
            mgr?.isEnabled = false
            mgr?.saveToPreferences { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.statusText = "已禁用"
                    self.active = false
                    completion()
                }
            }
            if mgr == nil { completion() }
        }
    }

    /// 已保存过配置时，App 启动后自动恢复透明代理
    func autoStartIfConfigured() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self, let mgr = managers?.first else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshScheduled = false
            self?.refreshStatus()
        }
    }

    func refreshStatus() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                return
            }
            guard let mgr = managers?.first else {
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

    private func configureAndStart() {
        if configuring { return }
        configuring = true
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            defer { self.configuring = false }
            if let error = error {
                self.lastError = error.localizedDescription
                self.statusText = "配置读取失败"
                return
            }
            let mgr = managers?.first ?? NETunnelProviderManager()
            self.manager = mgr
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = "127.0.0.1"
            proto.providerConfiguration = [
                "routes": ["172.30.0.0/16", "10.240.0.0/16"],
                "mtu": 1400,
            ]
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP 全局接管"
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
                    do {
                        try mgr.connection.startVPNTunnel()
                        self.statusText = "正在启动…"
                    } catch {
                        self.lastError = error.localizedDescription
                        self.statusText = "启动失败"
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
