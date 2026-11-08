import SwiftUI
import AppKit
import WebKit
import Combine

// SDP 代理 - 纯 Swift 实现（MenuBarExtra + 本地 SOCKS5/HTTP 代理）

@main
struct SDPApp: App {
    @NSApplicationDelegateAdaptor(SDPAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarIcon(connected: model.state == "connected")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let connected: Bool
    private var symbolName: String { connected ? "checkmark.shield.fill" : "shield.slash.fill" }

    var body: some View {
        if let img = Self.render(symbolName) {
            Image(nsImage: img)
        } else {
            Image(systemName: symbolName).fontWeight(.heavy)
        }
    }

    static func render(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .heavy)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }
}

enum PanelTab: String, CaseIterable {
    case sdp = "SDP"
    case wireguard = "WireGuard"
}

struct ResItem: Identifiable {
    let id = UUID()
    let domain: String
    let resid: String
    let ports: String
}

final class AppModel: ObservableObject {
    static weak var shared: AppModel?

    @Published var state = "login_required"
    @Published var username = ""
    @Published var sessionOK = false
    @Published var resourceCount = 0
    @Published var resources: [ResItem] = []
    @Published var qrURL = ""
    @Published var loginError = ""
    @Published var logsText = ""
    @Published var showLogs = false
    @Published var lastError = ""
    @Published var neStatus = "未启用"
    @Published var neActive = false

    let engine: Engine
    let ne = NEManager()
    let wg = WGManager()

    @Published var wgStatus = "未启用"
    @Published var wgActive = false
    @Published var wgError = ""
    @Published var wgConfigs: [WGConfig] = []
    @Published var wgActiveID: UUID?
    @Published var wgDraft = WGConfig()
    @Published var tab: PanelTab = .sdp
    private let server: ProxyServer
    private var cancellables = Set<AnyCancellable>()

    let home = NSHomeDirectory()
    var configPath: String { home + "/.sdp-proxy/config.json" }

    init() {
        engine = Engine()
        server = ProxyServer(engine: engine)
        AppModel.shared = self
        ensureDirs()

        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleSync()
            }
            .store(in: &cancellables)

        ne.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.neStatus = self.ne.statusText
                    self.neActive = self.ne.active
                    if !self.ne.lastError.isEmpty { self.lastError = self.ne.lastError }
                    self.engine.log("[NE] \(self.ne.statusText)\(self.ne.lastError.isEmpty ? "" : " err=\(self.ne.lastError)")")
                }
            }
            .store(in: &cancellables)

        wg.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.wgStatus = self.wg.statusText
                    self.wgActive = self.wg.active
                    self.wgError = self.wg.error
                    self.wgConfigs = self.wg.configs
                    self.wgActiveID = self.wg.activeID
                }
            }
            .store(in: &cancellables)

        server.start()
        Task { @MainActor in
            await engine.start()
            syncFromEngine()
            if engine.state == "login_required" {
                _ = await engine.beginLogin()
                syncFromEngine()
            }
            if ProcessInfo.processInfo.environment["SDP_NE_INSTALL"] == "1" {
                ne.enable(config: buildNEConfig())
            }
            if ProcessInfo.processInfo.environment["SDP_NE_AUTO"] == "1" {
                toggleNE()
            }
            if ProcessInfo.processInfo.environment["SDP_WG_AUTO"] == "1" {
                toggleWG()
            }
        }

        if ProcessInfo.processInfo.environment["SDP_NE_OFF"] == "1" {
            ne.disableAndRemoveConfig()
        } else {
            ne.refreshStatus()
            ne.autoStartIfConfigured()
        }
        wg.refresh()
        wgDraft = wg.activeConfig ?? WGConfig()
    }

    private var syncScheduled = false

    private func scheduleSync() {
        if syncScheduled { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.syncScheduled = false
            self?.syncFromEngine()
        }
    }

    private var lastSyncedState = ""
    private var lastToken = ""
    private var lastNEConfigKey = ""

    func syncFromEngine() {
        let previous = lastSyncedState
        lastSyncedState = engine.state
        if state != engine.state { state = engine.state }
        if username != engine.username { username = engine.username }
        if sessionOK != engine.sessionOK { sessionOK = engine.sessionOK }
        if qrURL != engine.qrURL { qrURL = engine.qrURL }
        if loginError != engine.loginError { loginError = engine.loginError }
        let liveToken = engine.token ?? ""
        if liveToken != lastToken {
            lastToken = liveToken
            SharedToken.write(engine.token)
        }
        // 登录成功后自动接管（首次或重新登录）
        let snapshotRules = engine.store.snapshot()
        let configKey = "\(snapshotRules.count)|\(snapshotRules.first?.pattern ?? "")"
        let neDisabledByEnv = ProcessInfo.processInfo.environment["SDP_NE_OFF"] == "1"
        if engine.state == "connected", !neDisabledByEnv, snapshotRules.count > 10, configKey != lastNEConfigKey {
            // 策略表加载完成后才下发扩展配置，避免用内置规则（错误 resid）启动
            lastNEConfigKey = configKey
            ne.enable(config: buildNEConfig())
        }
        if engine.state != "connected" { lastNEConfigKey = "" }

        let snapshot = engine.store.snapshot()
        if snapshot.count != resources.count {
            resources = snapshot.map {
                ResItem(domain: $0.pattern, resid: $0.resid, ports: $0.ports)
            }
            resourceCount = resources.count
        }
        // 日志只在面板展开时重建，避免高频写日志触发整面板刷新
        if showLogs {
            logsText = engine.logs.joined(separator: "\n")
        }
    }

    func relogin() {
        Task { @MainActor in
            await engine.logout()
            _ = await engine.beginLogin()
            syncFromEngine()
        }
    }

    func refreshQR() {
        Task { @MainActor in
            _ = await engine.refreshQR()
            syncFromEngine()
        }
    }

    func onScanned() {
        Task { await engine.onScanned() }
    }

    func saveWGConfig(_ cfg: WGConfig) {
        wg.upsert(cfg)
    }

    func saveWGDraft() {
        wg.upsert(wgDraft)
    }

    func selectWG(_ id: UUID) {
        wg.select(id)
        if let c = wg.activeConfig { wgDraft = c }
    }

    func deleteActiveWG() {
        wg.removeActive()
        wgDraft = wg.activeConfig ?? WGConfig()
    }

    func importWG(text: String, name: String) -> Bool {
        guard let cfg = WGManager.parseWgQuickConfig(text, fallbackName: name) else { return false }
        wg.upsert(cfg)
        wgDraft = cfg
        return true
    }

    func toggleWG() {
        if wg.active {
            wg.disable()
        } else {
            if wgDraft.valid { wg.upsert(wgDraft) }
            guard wg.activeConfig?.valid == true else {
                wgError = "请先填写或导入 WireGuard 配置"
                return
            }
            wg.enable()
        }
    }

    func toggleNE() {
        if ne.active {
            ne.disable()
        } else {
            ne.enable(config: buildNEConfig())
        }
    }

    /// 构建 Packet Tunnel 配置：token/网关/策略/路由
    func buildNEConfig() -> [String: Any] {
        let snapshot = engine.store.snapshot()
        var rules: [[String: String]] = []
        var routes = Set<String>()
        for r in snapshot {
            rules.append(["pattern": r.pattern, "resid": r.resid, "ports": r.ports])
            let p = r.pattern.lowercased()
            if p.contains("/") {
                routes.insert(p)
            } else if PublicDNS.isIPv4(p) {
                routes.insert(p + "/32")
            } else if p.contains("-") && p.filter({ $0 == "." }).count == 6 {
                let segs = p.split(separator: "-", maxSplits: 1)
                if segs.count == 2 {
                    for c in RuleText.ipRangeToCIDRs(String(segs[0]), String(segs[1])) {
                        routes.insert(c)
                    }
                }
            }
        }
        // 内部网段 + 公网入口段统一捕获，域名由 SNI 还原
        routes.insert("172.30.0.0/16")
        routes.insert("10.240.0.0/12")   // 内网 10.24x-10.25x，避免与 WireGuard 的 10.0.0.0/24 冲突
        routes.insert("122.191.10.0/24")

        var excludes = Set<String>(["127.0.0.1/32"])
        for gw in engine.cfg.gateway.split(separator: ",") {
            let host = String(gw).split(separator: ":").first.map(String.init) ?? ""
            if PublicDNS.isIPv4(host) { excludes.insert(host + "/32") }
            else if let ip = PublicDNS.resolveIPv4(host) { excludes.insert(ip + "/32") }
        }
        if let base = URL(string: engine.cfg.serverBase), let h = base.host, let ip = PublicDNS.resolveIPv4(h) {
            excludes.insert(ip + "/32")
        }
        // 内置直连域名（如 app.cscec5b.com.cn）是公网站点，不能收进隧道
        let directHosts = RuleStore.builtinDirectDomains + (engine.cfg.directDomains ?? [])
        for h in directHosts where !h.isEmpty {
            if PublicDNS.isIPv4(h) { excludes.insert(h + "/32") }
            else if let ip = PublicDNS.resolveIPv4(h) { excludes.insert(ip + "/32") }
        }

        return [
            "token": engine.token ?? "",
            "serverName": engine.cfg.serverName,
            "gateways": engine.cfg.gateway.split(separator: ",").map(String.init),
            "rules": rules,
            "directDomains": engine.cfg.directDomains ?? [],
            "routes": Array(routes),
            "excludeRoutes": Array(excludes),
            "mtu": 1400,
        ]
    }

    func quit() {
        server.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - 系统代理

    private func ensureDirs() {
        try? FileManager.default.createDirectory(atPath: home + "/.sdp-proxy", withIntermediateDirectories: true)
    }

    func uiAddress() -> String {
        let (_, port) = SDPConfig.splitHostPort(engine.cfg.uiListen)
        return "127.0.0.1:\(port)"
    }

    func shutdownSynchronously() {
        server.stop()
    }
}

// MARK: - 应用退出清理

final class SDPAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.shutdownSynchronously()
    }
}
