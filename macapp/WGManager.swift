import Foundation
import NetworkExtension
import SystemExtensions
import Combine

struct WGConfig: Codable, Equatable {
    var privateKey = ""
    var address = ""
    var dns = ""
    var peerPublicKey = ""
    var endpoint = ""
    var allowedIPs = "0.0.0.0/0"
    var keepalive = "25"
}

/// WireGuard 系统扩展管理（Packet Tunnel）
final class WGManager: NSObject, ObservableObject {
    static let extensionID = "com.alick.sdp-proxy.wg"
    static var configPath: String { NSHomeDirectory() + "/.sdp-proxy/wireguard.json" }

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var error = ""
    @Published var config = WGConfig()

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false

    override init() {
        super.init()
        loadConfig()
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let conn = note.object as? NEVPNConnection,
                  conn === self.manager?.connection else { return }
            self.scheduleRefresh()
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.configPath)),
              let cfg = try? JSONDecoder().decode(WGConfig.self, from: data) else { return }
        config = cfg
    }

    func saveConfig(_ cfg: WGConfig) {
        config = cfg
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(cfg).write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
    }

    var configured: Bool {
        !config.privateKey.isEmpty && !config.peerPublicKey.isEmpty && !config.endpoint.isEmpty
    }

    func enable() {
        NSLog("[WG] 请求安装扩展 %@", Self.extensionID)
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        manager?.connection.stopVPNTunnel()
        active = false
        statusText = "已关闭"
    }

    private func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, err in
            guard let self = self else { return }
            if let err = err { self.error = err.localizedDescription; return }
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
                self.statusText = "已连接"
                self.active = true
            case .connecting, .reasserting:
                self.statusText = "正在连接…"
                self.active = true
            case .disconnecting:
                self.statusText = "正在断开…"
                self.active = false
            default:
                self.statusText = "已关闭"
                self.active = false
            }
        }
    }

    private func configureAndStart() {
        guard configured else {
            statusText = "扩展已安装，请填写配置"
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, err in
            guard let self = self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
            }) ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = self.config.endpoint
            proto.providerConfiguration = [
                "privateKey": self.config.privateKey,
                "addresses": self.splitList(self.config.address),
                "dns": self.splitList(self.config.dns),
                "peerPublicKey": self.config.peerPublicKey,
                "endpoint": self.config.endpoint,
                "allowedIPs": self.splitList(self.config.allowedIPs),
                "persistentKeepalive": Int(self.config.keepalive) ?? 25,
            ]
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP WireGuard"
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                if let error = error {
                    self.error = error.localizedDescription
                    self.statusText = "配置保存失败"
                    return
                }
                mgr.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        self.error = loadError.localizedDescription
                        self.statusText = "配置重载失败"
                        return
                    }
                    do {
                        try mgr.connection.startVPNTunnel()
                        self.statusText = "正在连接…"
                    } catch {
                        self.error = error.localizedDescription
                        self.statusText = "启动失败"
                    }
                    self.refresh()
                }
            }
        }
    }

    private func splitList(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension WGManager: OSSystemExtensionRequestDelegate {
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
        statusText = "扩展已安装"
        configureAndStart()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        NSLog("[WG] 安装失败: %@", error.localizedDescription)
        self.error = error.localizedDescription
        statusText = "扩展安装失败"
    }
}
