import Foundation
import NetworkExtension
import CryptoKit
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
    var onDemand = false

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
        onDemand = try c.decodeIfPresent(Bool.self, forKey: .onDemand) ?? false
    }

    var publicKey: String? {
        WGConfig.derivePublicKey(privateKey)
    }

    static func derivePublicKey(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
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
/// `@unchecked Sendable`：NE 的 @Sendable 回调需要捕获 self；状态仅在主队列读写。
final class WGManager: NSObject, ObservableObject, @unchecked Sendable {
    static let extensionID = "com.alick.sdp-proxy.wg"
    static var configPath: String { NSHomeDirectory() + "/.sdp-proxy/wireguard.json" }

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var error = ""
    @Published var configs: [WGConfig] = []
    @Published var activeID: UUID?
    @Published var logs: [String] = []

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false
    private var logFileBytes = -1
    private var pollTimer: Timer?
    private var lastRuntimeLine = ""
    private var lastHandshake: Int = 0

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

    static var logPath: String { NSHomeDirectory() + "/.sdp-proxy/wireguard.log" }

    private func log(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(msg)"
        logs.append(line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        if let data = (line + "\n").data(using: .utf8) {
            let fm = FileManager.default
            if logFileBytes < 0 {
                logFileBytes = (try? fm.attributesOfItem(atPath: Self.logPath))?[.size] as? Int ?? 0
            }
            let limit = 2 * 1024 * 1024
            if logFileBytes > limit {
                let backup = Self.logPath + ".1"
                try? fm.removeItem(atPath: backup)
                if logFileBytes > limit * 2 {
                    try? fm.removeItem(atPath: Self.logPath)
                } else {
                    try? fm.moveItem(atPath: Self.logPath, toPath: backup)
                }
                logFileBytes = 0
            }
            if let h = FileHandle(forWritingAtPath: Self.logPath) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: Self.logPath))
            }
            logFileBytes += data.count
        }
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
        log("选择配置: \(configs.first(where: { $0.id == id })?.displayName ?? "-")")
        activeID = id
        persist()
    }

    func upsert(_ cfg: WGConfig) {
        log("保存配置: \(cfg.displayName) mtu=\(cfg.mtu)")
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
        log("请求安装/激活扩展")
        NSLog("[WG] 请求安装扩展 %@", Self.extensionID)
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func disable() {
        log("断开连接")
        manager?.connection.stopVPNTunnel()
        active = false
        statusText = "已关闭"
    }

    // MARK: - 运行时状态轮询（握手/RX/TX）

    private func startPolling() {
        if pollTimer != nil { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollRuntime()
        }
        pollRuntime()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollRuntime() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("status".utf8)) { [weak self] data in
            guard let self = self, let data = data,
                  let text = String(data: data, encoding: .utf8) else { return }
            self.handleRuntime(text)
        }
    }

    private func handleRuntime(_ text: String) {
        var peers = 0
        var handshake = 0
        var rx = 0
        var tx = 0
        var currentHandshake = 0
        var currentRx = 0
        var currentTx = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            if key == "public_key" {
                if peers > 0 {
                    handshake = max(handshake, currentHandshake)
                    rx += currentRx; tx += currentTx
                }
                peers += 1
                currentHandshake = 0; currentRx = 0; currentTx = 0
            } else if key == "last_handshake_time_sec" {
                currentHandshake = Int(value) ?? 0
            } else if key == "rx_bytes" {
                currentRx = Int(value) ?? 0
            } else if key == "tx_bytes" {
                currentTx = Int(value) ?? 0
            }
        }
        if peers > 0 {
            handshake = max(handshake, currentHandshake)
            rx += currentRx; tx += currentTx
        }
        let line = "[NET] Runtime config summary: peers=\(peers) last_handshake_time_sec=\(handshake) rx_bytes=\(rx) tx_bytes=\(tx)"
        if line != lastRuntimeLine {
            lastRuntimeLine = line
            log(line)
        }
        if handshake > 0 && handshake != lastHandshake {
            lastHandshake = handshake
            log("[NET] handshake 成功 time=\(handshake)")
        }
    }

    private func intValue(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    private func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        // Swift 6：@Sendable 闭包不能直接捕获非 Sendable 的 self，这里保留弱引用语义
        nonisolated(unsafe) weak var me = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            me?.refreshScheduled = false
            me?.refresh()
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
                if !self.active {
                    self.log("隧道已连接")
                    self.lastRuntimeLine = ""
                    self.lastHandshake = 0
                }
                self.statusText = "已连接"
                self.active = true
                self.startPolling()
            case .connecting, .reasserting:
                self.statusText = "正在连接…"
                self.active = true
            case .disconnecting:
                self.statusText = "正在断开…"
                self.active = false
            default:
                if self.active { self.log("隧道已断开") }
                self.statusText = "已关闭"
                self.active = false
                self.stopPolling()
            }
        }
    }

    private func configureAndStart() {
        guard let cfg = activeConfig, cfg.valid else {
            log("配置无效：需要 PrivateKey / PublicKey / Endpoint")
            statusText = "扩展已安装，请填写或导入配置"
            return
        }
        log("启动配置: \(cfg.displayName) endpoint=\(cfg.endpoint) mtu=\(cfg.mtu)")
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
            if cfg.onDemand {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                mgr.onDemandRules = [rule]
                mgr.isOnDemandEnabled = true
            } else {
                mgr.onDemandRules = []
                mgr.isOnDemandEnabled = false
            }
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
                        // Swift 6：manager 非 Sendable，显式放行跨闭包传递
                        nonisolated(unsafe) let manager = mgr
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            do { try manager.connection.startVPNTunnel(); self.statusText = "正在连接…" }
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
        log("扩展已就绪")
        statusText = "扩展已安装"
        configureAndStart()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        log("扩展安装失败: \(error.localizedDescription)")
        NSLog("[WG] 安装失败: %@", error.localizedDescription)
        self.error = error.localizedDescription
        statusText = "扩展安装失败"
    }
}
