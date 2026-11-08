import Foundation
import NetworkExtension
import SystemExtensions
import Combine

struct WGConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var privateKey = ""
    var address = ""
    var dns = ""
    var peerPublicKey = ""
    var endpoint = ""
    var allowedIPs = "0.0.0.0/0"
    var keepalive = "25"
    var mtu = "1420"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        privateKey = try c.decodeIfPresent(String.self, forKey: .privateKey) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        dns = try c.decodeIfPresent(String.self, forKey: .dns) ?? ""
        peerPublicKey = try c.decodeIfPresent(String.self, forKey: .peerPublicKey) ?? ""
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        allowedIPs = try c.decodeIfPresent(String.self, forKey: .allowedIPs) ?? "0.0.0.0/0"
        keepalive = try c.decodeIfPresent(String.self, forKey: .keepalive) ?? "25"
        mtu = try c.decodeIfPresent(String.self, forKey: .mtu) ?? "1420"
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !endpoint.isEmpty { return endpoint }
        return "未命名配置"
    }

    var valid: Bool {
        !privateKey.isEmpty && !peerPublicKey.isEmpty && !endpoint.isEmpty
    }
}

struct WGStore: Codable {
    var configs: [WGConfig] = []
    var activeID: UUID?
}

/// WireGuard 系统扩展管理（Packet Tunnel），支持多配置
final class WGManager: NSObject, ObservableObject {
    static let extensionID = "com.alick.sdp-proxy.wg"
    static var configPath: String { NSHomeDirectory() + "/.sdp-proxy/wireguard.json" }

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var error = ""
    @Published var configs: [WGConfig] = []
    @Published var activeID: UUID?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false

    override init() {
        super.init()
        loadStore()
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

    var activeConfig: WGConfig? {
        configs.first { $0.id == activeID } ?? configs.first
    }

    // MARK: - 配置存储

    func loadStore() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.configPath)) else { return }
        let dec = JSONDecoder()
        if let store = try? dec.decode(WGStore.self, from: data) {
            configs = store.configs
            activeID = store.activeID
        } else if let old = try? dec.decode(WGConfig.self, from: data) {
            // 兼容旧的单配置格式
            var cfg = old
            if cfg.name.isEmpty { cfg.name = cfg.endpoint }
            configs = [cfg]
            activeID = cfg.id
            persist()   // 旧单配置格式立即迁移为多配置格式
        }
        if activeConfig == nil { activeID = configs.first?.id }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let store = WGStore(configs: configs, activeID: activeID)
        try? enc.encode(store).write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
    }

    func select(_ id: UUID) {
        activeID = id
        persist()
    }

    func upsert(_ cfg: WGConfig) {
        var c = cfg
        if c.name.isEmpty { c.name = c.endpoint }
        if let idx = configs.firstIndex(where: { $0.id == c.id }) {
            configs[idx] = c
        } else {
            configs.append(c)
        }
        activeID = c.id
        persist()
    }

    func removeActive() {
        guard let id = activeID else { return }
        configs.removeAll { $0.id == id }
        activeID = configs.first?.id
        persist()
    }

    // MARK: - 导入

    /// 解析 wg-quick 格式配置文本
    static func parseWgQuickConfig(_ text: String, fallbackName: String) -> WGConfig? {
        var cfg = WGConfig()
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            switch (section, key) {
            case ("[interface]", "privatekey"): cfg.privateKey = value
            case ("[interface]", "address"): cfg.address = value
            case ("[interface]", "dns"): cfg.dns = value
            case ("[interface]", "mtu"): cfg.mtu = value
            case ("[peer]", "publickey"): cfg.peerPublicKey = value
            case ("[peer]", "endpoint"): cfg.endpoint = value
            case ("[peer]", "allowedips"): cfg.allowedIPs = value
            case ("[peer]", "persistentkeepalive"): cfg.keepalive = value
            default: break
            }
        }
        guard cfg.valid else { return nil }
        cfg.name = cfg.endpoint.isEmpty ? fallbackName : cfg.endpoint
        return cfg
    }

    // MARK: - 连接

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
        guard let cfg = activeConfig, cfg.valid else {
            statusText = "扩展已安装，请填写或导入配置"
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
            proto.serverAddress = cfg.endpoint
            var providerConfig: [String: Any] = [
                "privateKey": cfg.privateKey,
                "addresses": self.splitList(cfg.address),
                "dns": self.splitList(cfg.dns),
                "peerPublicKey": cfg.peerPublicKey,
                "endpoint": cfg.endpoint,
                "allowedIPs": self.splitList(cfg.allowedIPs),
                "persistentKeepalive": Int(cfg.keepalive) ?? 25,
            ]
            if let mtu = Int(cfg.mtu), mtu >= 576 { providerConfig["mtu"] = mtu }
            proto.providerConfiguration = providerConfig
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
                    if mgr.connection.status == .connected || mgr.connection.status == .connecting {
                        mgr.connection.stopVPNTunnel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            do { try mgr.connection.startVPNTunnel(); self.statusText = "正在连接…" }
                            catch { self.error = error.localizedDescription; self.statusText = "启动失败" }
                        }
                    } else {
                        do {
                            try mgr.connection.startVPNTunnel()
                            self.statusText = "正在连接…"
                        } catch {
                            self.error = error.localizedDescription
                            self.statusText = "启动失败"
                        }
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
