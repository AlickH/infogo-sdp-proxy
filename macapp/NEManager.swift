import Foundation
import NetworkExtension
import SystemExtensions
import Combine

/// 系统扩展（透明代理）管理：安装 → 配置 → 启动
final class NEManager: NSObject, ObservableObject {
    static let extensionID = "com.alick.sdp-proxy.ne"

    @Published var statusText = "未启用" {
        didSet { NSLog("[NE] 状态: %@", statusText) }
    }
    @Published var active = false
    @Published var lastError = ""

    private var manager: NETransparentProxyManager?
    private var socksPort: UInt16 = 11095
    private var observer: NSObjectProtocol?

    private func dbg(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let path = NSHomeDirectory() + "/.sdp-proxy/ne.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
    private let queue = DispatchQueue.main

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 开关

    func enable(socksPort: UInt16) {
        self.socksPort = socksPort
        dbg("enable() socks=\(socksPort)")
        NSLog("[NE] 请求安装扩展 %@ (socks %d)", Self.extensionID, Int(socksPort))
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: queue)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        manager?.connection.stopVPNTunnel()
        statusText = "已关闭"
        active = false
    }

    // MARK: - 状态

    func refreshStatus() {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
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
            self.dbg("refresh status=\(mgr.connection.status.rawValue) enabled=\(mgr.isEnabled)")
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
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                self.statusText = "配置读取失败"
                return
            }
            let mgr = managers?.first ?? NETransparentProxyManager()
            self.manager = mgr
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = "127.0.0.1"
            proto.providerConfiguration = [
                "socksHost": "127.0.0.1",
                "socksPort": Int(self.socksPort),
            ]
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP 全局接管"
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                self.dbg("saveToPreferences error=\(String(describing: error))")
                if let error = error {
                    self.lastError = error.localizedDescription
                    self.statusText = "配置保存失败"
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

extension NEManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        NSLog("[NE] 需要用户在系统设置中批准")
        statusText = "等待系统批准扩展…"
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            dbg("activation completed")
            statusText = "扩展已安装"
            configureAndStart()
        case .willCompleteAfterReboot:
            statusText = "需要重启后生效"
        @unknown default:
            statusText = "扩展安装完成（未知结果）"
            configureAndStart()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        NSLog("[NE] 安装失败: %@", error.localizedDescription)
        lastError = error.localizedDescription
        statusText = "扩展安装失败"
    }
}
