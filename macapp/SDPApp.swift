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
    case tailscale = "Tailscale"
}

struct ResItem: Identifiable {
    let id = UUID()
    let domain: String
    let resid: String
    let ports: String
}

/// `@unchecked Sendable`：Engine 的回调/定时器会把 self 带进 Task；所有 @Published 更新都在主队列。
final class AppModel: ObservableObject, @unchecked Sendable {
    // 仅主线程读写（SwiftUI 视图生命周期内），Swift 6 下显式声明为 unsafe 全局状态
    nonisolated(unsafe) static weak var shared: AppModel?

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
    let ts = TSManager()

    @Published var wgStatus = "未启用"
    @Published var wgActive = false
    @Published var wgError = ""
    @Published var wgConfigs: [WGConfig] = []
    @Published var wgActiveID: UUID?
    @Published var wgDraft = WGConfig()
    @Published var wgLogsText = ""

    @Published var tsStatus = "未启用"
    @Published var tsActive = false
    @Published var tsError = ""
    @Published var tsConfigs: [TSConfig] = []
    @Published var tsActiveID: UUID?
    @Published var tsDraft = TSConfig()
    @Published var tsLogsText = ""
    @Published var tsBackendState = ""
    @Published var tsSelfIP = "-"
    @Published var tsTailnet = ""
    @Published var tsLoginURL = ""
    @Published var tsPeers: [TSPeer] = []
    @Published var tsTrafficText = ""
    @Published var tsNeedsRelocation = false

    @Published var tab: PanelTab = .sdp

    // VPN 总开关：与三个功能开关完全解耦
    @Published var vpnWanted = MergedVPN.shared.wanted
    @Published var vpnConnected = false
    @Published var vpnStatus = "未连接"

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
                    self.neActive = MergedTunnel.shared.isEnabled("sdp")
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
                    self.wgActive = MergedTunnel.shared.isEnabled("wg")
                    self.wgError = self.wg.error
                    self.wgConfigs = self.wg.configs
                    self.wgActiveID = self.wg.activeID
                    self.wgLogsText = self.wg.logs.joined(separator: "\n")
                }
            }
            .store(in: &cancellables)

        ts.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.tsStatus = self.ts.statusText
                    self.tsActive = MergedTunnel.shared.isEnabled("ts")
                    self.tsError = self.ts.error
                    self.tsConfigs = self.ts.configs
                    self.tsActiveID = self.ts.activeID
                    self.tsLogsText = self.ts.logs.joined(separator: "\n")
                    self.tsBackendState = self.ts.backendState
                    self.tsSelfIP = self.ts.selfIP
                    self.tsTailnet = self.ts.tailnet
                    self.tsLoginURL = self.ts.loginURL
                    self.tsPeers = self.ts.peers
                    self.tsTrafficText = self.ts.trafficText
                    self.tsNeedsRelocation = self.ts.needsRelocation
                }
            }
            .store(in: &cancellables)

        MergedVPN.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.vpnWanted = MergedVPN.shared.wanted
                    self.vpnConnected = MergedVPN.shared.connected
                    self.vpnStatus = MergedVPN.shared.statusText
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
            if ProcessInfo.processInfo.environment["SDP_TS_AUTO"] == "1" {
                toggleTS()
            }
        }

        if ProcessInfo.processInfo.environment["SDP_NE_OFF"] == "1" {
            ne.disableAndRemoveConfig()
        } else {
            ne.refreshStatus()
            // 只有总开关开着才恢复连接；功能开关不再负责拉起隧道
            MergedVPN.shared.restore()
        }
        syncFeatureFlags()
        wg.refresh()
        wgDraft = wg.activeConfig ?? WGConfig()
        ts.refresh()
        tsDraft = ts.activeConfig ?? TSConfig()
    }

    func syncWGLogs() {
        wgLogsText = wg.logs.joined(separator: "\n")
    }

    func syncTSLogs() {
        tsLogsText = ts.logs.joined(separator: "\n")
    }

    func syncLogsForCurrentTab() {
        switch tab {
        case .sdp: syncFromEngine()
        case .wireguard: syncWGLogs()
        case .tailscale: syncTSLogs()
        }
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
            // 策略表加载完成后才刷新扩展配置，避免用内置规则（错误 resid）启动。
            // 只更新配置，不擅自改功能开关，也不重新激活扩展。
            lastNEConfigKey = configKey
            if MergedTunnel.shared.isEnabled("sdp") {
                MergedTunnel.shared.set("sdp", enabled: true, config: buildNEConfig())
                MergedVPN.shared.applyFeatures()
            }
        }
        if engine.state != "connected" {
            // 只重置配置指纹；登录状态不该动「是否启用 SDP 功能」这个用户选择。
            // 连不连网由 VPN 总开关决定。
            lastNEConfigKey = ""
        }

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

    func newWGConfigDraft() {
        wgDraft = WGConfig()
    }

    func editWGDraft(_ id: UUID) {
        if let c = wgConfigs.first(where: { $0.id == id }) { wgDraft = c }
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

    /// VPN 总开关：只管连不连网，不动三个功能各自的启用状态
    func toggleVPN() {
        MergedVPN.shared.setWanted(!MergedVPN.shared.wanted)
    }

    /// 页面开关的唯一真相是 MergedTunnel.features，与隧道连没连无关
    func syncFeatureFlags() {
        neActive = MergedTunnel.shared.isEnabled("sdp")
        wgActive = MergedTunnel.shared.isEnabled("wg")
        tsActive = MergedTunnel.shared.isEnabled("ts")
    }

    /// 页面开关：只登记 WireGuard 是否参与这条隧道。
    /// 总开关关着时不会连网；开着时由 configureAndStart 热重连应用新配置。
    func toggleWG() {
        if MergedTunnel.shared.isEnabled("wg") {
            wg.disable()
        } else {
            if wgDraft.valid { wg.upsert(wgDraft) }
            guard wg.activeConfig?.valid == true else {
                wgError = "请先填写或导入 WireGuard 配置"
                return
            }
            MergedTunnel.shared.set("wg", enabled: true)
            wg.configureAndStart()
        }
        syncFeatureFlags()
    }

    // MARK: - Tailscale

    func saveTSConfig(_ cfg: TSConfig) {
        ts.upsert(cfg)
    }

    func saveTSDraft() {
        ts.upsert(tsDraft)
    }

    func newTSConfigDraft() {
        tsDraft = TSConfig()
    }

    func editTSDraft(_ id: UUID) {
        if let c = tsConfigs.first(where: { $0.id == id }) { tsDraft = c }
    }

    func selectTS(_ id: UUID) {
        ts.select(id)
        if let c = ts.activeConfig { tsDraft = c }
    }

    func deleteActiveTS() {
        ts.removeActive()
        tsDraft = ts.activeConfig ?? TSConfig()
    }

    func toggleTS() {
        if MergedTunnel.shared.isEnabled("ts") {
            ts.disable()
        } else {
            if tsDraft.valid { ts.upsert(tsDraft) }
            guard ts.activeConfig?.valid == true else {
                tsError = "请先填写 Tailscale 配置（Control URL）"
                return
            }
            MergedTunnel.shared.set("ts", enabled: true)
            ts.configureAndStart()
        }
        syncFeatureFlags()
    }

    func openTSLogin() { ts.openLoginPage() }
    func logoutTS() { ts.logout() }
    func loginTS() { ts.login() }
    func reloginTS() { ts.relogin() }
    func relocateTS() { ts.relocateToApplications() }
    func activateTSExtension() { ts.enable() }
    func activateWGExtension() { wg.enable() }

    func toggleNE() {
        if MergedTunnel.shared.isEnabled("sdp") {
            ne.disable()
        } else {
            MergedTunnel.shared.set("sdp", enabled: true, config: buildNEConfig())
            ne.configureAndStart()
        }
        syncFeatureFlags()
    }

    /// 构建 Packet Tunnel 配置：token/网关/策略/路由
    /// 一次性迁移到合并隧道：清理旧配置后，顺序下发三份配置。
    /// 每次 configureAndStart 都会保存并重启隧道，最后一次配置才完整。
    /// 之后正常启动靠 UserDefaults 里持久化的 features + 已保存的 providerConfiguration。
    func setupMergedAllFeatures() {
        let cfg = buildNEConfig()
        MergedTunnel.shared.set("sdp", enabled: true, config: cfg)
        ne.enable(config: cfg)
        // 迁移要把三个开关都真正打开。WG/TS 有配置才启用；且必须在各自 configureAndStart
        // 之前 set enabled=true，否则 configureAndStart 内的「跟随 shared 状态」逻辑不会写入
        // 它们的 config，合并隧道只会剩下 SDP 生效。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self = self else { return }
            if let c = self.wg.activeConfig, c.valid {
                MergedTunnel.shared.set("wg", enabled: true)
            }
            self.wg.configureAndStart()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self else { return }
                if let c = self.ts.activeConfig, c.valid {
                    MergedTunnel.shared.set("ts", enabled: true)
                }
                self.ts.configureAndStart()
            }
        }
    }

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
        routes.insert("10.240.0.0/12")   // 内网 10.24x-10.25x，避开 WireGuard 的 10.0.0.0/24
        // Tailscale 节点地址在 100.64.0.0/10（CGNAT 段），不在此捕获，三个隧道可并存
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
    /// 支持 `--ts-login` 启动参数：启动后直接走一遍「一键登录 Tailscale」，
    /// 方便脚本化安装/排障（等价于在面板里点一次「登录 Tailscale」）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--merged-setup") {
            MergedTunnel.cleanupLegacyConfigs {
                AppModel.shared?.setupMergedAllFeatures()
            }
            return
        }
        // 只提交一次激活请求：用于把 /Applications 里的新扩展版本推送到系统（升级）
        if args.contains("--ts-activate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppModel.shared?.activateTSExtension()
            }
            return
        }
        if args.contains("--wg-activate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                AppModel.shared?.activateWGExtension()
            }
            return
        }
        guard args.contains("--ts-login") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            AppModel.shared?.loginTS()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.shutdownSynchronously()
    }
}
