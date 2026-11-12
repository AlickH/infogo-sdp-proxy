import Foundation
import AppKit
import NetworkExtension
import SystemExtensions
import Combine

// MARK: - 配置模型

/// Tailscale 节点配置。
///
/// `authKey` 留空时走交互式登录：扩展启动后通过 `status` 消息返回 `authURL`，
/// 用户在浏览器完成 SSO 后节点自动上线。填入 `tskey-...` 则为预授权（无人值守）登录。
/// `controlURL` 可指向自建 Headscale，默认使用 Tailscale 官方控制面。
struct TSConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var controlURL = "https://controlplane.tailscale.com"
    var authKey = ""
    var hostname = ""
    /// 隧道捕获的网段（Tailscale 默认 CGNAT 段，与 SDP 的 10.240.0.0/12、WG 的 10.0.0.0/24 不冲突）
    var routes = "100.64.0.0/10"
    var acceptDNS = true
    var mtu = "1280"
    var onDemand = false

    // 以下三项底层 tsnet 引擎不支持，保留字段只为兼容旧配置文件的反序列化，
    // 界面上已不再展示：advertiseRoutes（广播子网）、exitNode、shieldIncoming。
    // acceptRoutes 也无意义——tsnet 会自动接受对端广播的子网路由。
    var advertiseRoutes = ""
    var exitNode = ""
    var acceptRoutes = true
    var shieldIncoming = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, controlURL, authKey, hostname, routes
        case advertiseRoutes, exitNode, acceptDNS, acceptRoutes
        case shieldIncoming, mtu, onDemand
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        controlURL = try c.decodeIfPresent(String.self, forKey: .controlURL) ?? "https://controlplane.tailscale.com"
        authKey = try c.decodeIfPresent(String.self, forKey: .authKey) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        routes = try c.decodeIfPresent(String.self, forKey: .routes) ?? "100.64.0.0/10"
        advertiseRoutes = try c.decodeIfPresent(String.self, forKey: .advertiseRoutes) ?? ""
        exitNode = try c.decodeIfPresent(String.self, forKey: .exitNode) ?? ""
        acceptDNS = try c.decodeIfPresent(Bool.self, forKey: .acceptDNS) ?? true
        acceptRoutes = try c.decodeIfPresent(Bool.self, forKey: .acceptRoutes) ?? true
        shieldIncoming = try c.decodeIfPresent(Bool.self, forKey: .shieldIncoming) ?? false
        mtu = try c.decodeIfPresent(String.self, forKey: .mtu) ?? "1280"
        onDemand = try c.decodeIfPresent(Bool.self, forKey: .onDemand) ?? false
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !hostname.isEmpty { return hostname }
        if let host = URL(string: controlURL)?.host { return host }
        return "未命名配置"
    }

    var valid: Bool {
        guard let host = URL(string: controlURL)?.host, !host.isEmpty else { return false }
        return true
    }

    var loginMode: String { authKey.isEmpty ? "交互式登录" : "Auth Key" }
}

struct TSStore: Codable {
    var configs: [TSConfig] = []
    var activeID: UUID?
}

/// 扩展上报的一个对端节点
struct TSPeer: Decodable, Equatable, Identifiable {
    var id: String { ip.isEmpty ? name : ip }
    var name = ""
    var ip = ""
    var online = false
    var direct = false
    var os = ""
    var relay = ""

    init() {}

    enum CodingKeys: String, CodingKey { case name, ip, online, direct, os, relay }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        direct = try c.decodeIfPresent(Bool.self, forKey: .direct) ?? false
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        relay = try c.decodeIfPresent(String.self, forKey: .relay) ?? ""
    }
}

/// 合并后的系统扩展通过 `status` 消息返回的运行时快照（JSON）
struct TSRuntimeStatus: Decodable {
    var backendState = ""
    var selfIPs: [String] = []
    var authURL = ""
    var tailnet = ""
    var peers: [TSPeer] = []
    var rxBytes: Int64 = 0
    var txBytes: Int64 = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case backendState, selfIPs, authURL, tailnet, peers, rxBytes, txBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try c.decodeIfPresent(String.self, forKey: .backendState) ?? ""
        selfIPs = try c.decodeIfPresent([String].self, forKey: .selfIPs) ?? []
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        tailnet = try c.decodeIfPresent(String.self, forKey: .tailnet) ?? ""
        peers = try c.decodeIfPresent([TSPeer].self, forKey: .peers) ?? []
        rxBytes = try c.decodeIfPresent(Int64.self, forKey: .rxBytes) ?? 0
        txBytes = try c.decodeIfPresent(Int64.self, forKey: .txBytes) ?? 0
    }
}

/// Tailscale 系统扩展管理（Packet Tunnel），支持多配置
/// `@unchecked Sendable`：NE 的 @Sendable 回调需要捕获 self；状态仅在主队列读写。
final class TSManager: NSObject, ObservableObject, @unchecked Sendable {
    static let extensionID = MergedTunnel.extensionID
    static var configPath: String { NSHomeDirectory() + "/.sdp-proxy/tailscale.json" }
    static var logPath: String { NSHomeDirectory() + "/.sdp-proxy/tailscale.log" }

    @Published var statusText = "未启用"
    @Published var active = false
    @Published var error = ""
    @Published var configs: [TSConfig] = []
    @Published var activeID: UUID?
    @Published var logs: [String] = []

    @Published var backendState = ""
    @Published var selfIPs: [String] = []
    @Published var tailnet = ""
    @Published var loginURL = ""
    @Published var peers: [TSPeer] = []
    @Published var trafficText = ""
    /// App 不在 /Applications 时置位：系统扩展无法激活，UI 需要给出「搬到应用程序」入口
    @Published var needsRelocation = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false
    private var logFileBytes = -1
    private var pollTimer: Timer?
    private var lastRuntimeLine = ""
    /// 上一次记录的在线节点 IP，用于只在集合变化时打日志
    private var lastOnlinePeerIPs: [String] = []
    /// 用户主动发起交互式登录时置位：authURL 一到就自动拉起浏览器（只拉一次）
    private var autoOpenLogin = false
    /// 持有清理器，避免请求还没回来就被释放
    private var recordCleaner: SXRecordCleaner?

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
        stopPolling()
    }

    var activeConfig: TSConfig? {
        configs.first { $0.id == activeID } ?? configs.first
    }

    /// 优先展示 Tailscale IPv4（100.x.y.z）
    var selfIP: String {
        selfIPs.first(where: { !$0.contains(":") }) ?? selfIPs.first ?? "-"
    }

    var needsLogin: Bool { !loginURL.isEmpty }

    /// 系统扩展只能由「位于 /Applications 的 App」激活，这是 macOS 的硬性要求。
    /// 直接跑 dist/ 或任意目录下的 .app 都会得到
    /// "App containing System Extension to be activated must be in /Applications folder"。
    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    static var currentLocationHint: String {
        Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    // MARK: - 日志

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

    // MARK: - 配置存储

    func loadStore() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.configPath)) else { return }
        let dec = JSONDecoder()
        if let store = try? dec.decode(TSStore.self, from: data) {
            configs = store.configs
            activeID = store.activeID
        } else if let old = try? dec.decode(TSConfig.self, from: data) {
            // 兼容旧的单配置格式
            configs = [old]
            activeID = old.id
            persist()
        }
        if activeConfig == nil { activeID = configs.first?.id }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let store = TSStore(configs: configs, activeID: activeID)
        try? enc.encode(store).write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
    }

    func select(_ id: UUID) {
        log("选择配置: \(configs.first(where: { $0.id == id })?.displayName ?? "-")")
        activeID = id
        persist()
    }

    func upsert(_ cfg: TSConfig) {
        log("保存配置: \(cfg.displayName) control=\(cfg.controlURL) \(cfg.loginMode)")
        var c = cfg
        if c.name.isEmpty { c.name = c.displayName }
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

    // MARK: - 连接

    func enable() {
        MergedTunnel.shared.set("ts", enabled: true)
        guard Self.isInApplicationsFolder else {
            needsRelocation = true
            statusText = "扩展安装失败"
            error = "系统扩展只能从「应用程序」文件夹激活。当前 App 在 \(Self.currentLocationHint)，请点下方按钮搬到 /Applications 后重试。"
            log("App 不在 /Applications，无法激活系统扩展")
            return
        }
        needsRelocation = false
        log("请求安装/激活扩展")
        NSLog("[TS] 请求安装扩展 %@", Self.extensionID)
        statusText = "正在安装扩展…"
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// 把自身拷进 /Applications 再重启——系统扩展激活的前置条件
    func relocateToApplications() {
        let src = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let dst = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        guard src.standardizedFileURL.path != dst.standardizedFileURL.path else {
            needsRelocation = false
            return
        }
        statusText = "正在安装到「应用程序」…"
        log("拷贝 \(src.path) → \(dst.path)")
        nonisolated(unsafe) let srcURL = src
        nonisolated(unsafe) let dstURL = dst
        DispatchQueue.global(qos: .userInitiated).async {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = [srcURL.path, dstURL.path]
            var ok = false
            do {
                try ditto.run()
                ditto.waitUntilExit()
                ok = ditto.terminationStatus == 0
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                guard ok else {
                    self.statusText = "安装失败"
                    self.error = "无法写入 /Applications，请手动把 SDP.app 拖进「应用程序」文件夹"
                    return
                }
                self.log("已安装到 /Applications，正在重启…")
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [dstURL.path]
                try? open.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func disable() {
        log("关闭 Tailscale 功能")
        MergedTunnel.shared.set("ts", enabled: false)
        if MergedTunnel.shared.isEmpty {
            manager?.connection.stopVPNTunnel()
        } else {
            configureAndStart()
        }
        active = false
        statusText = "已关闭"
        stopPolling()
        clearRuntime()
    }

    /// 打开扩展返回的交互式登录链接（SSO）
    func openLoginPage() {
        guard let url = URL(string: loginURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            error = "当前没有可用的登录链接"
            return
        }
        log("打开登录链接")
        NSWorkspace.shared.open(url)
    }

    /// 让扩展退出当前 tailnet 登录态
    func logout() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        log("请求退出登录")
        try? session.sendProviderMessage(MergedTunnel.command("ts", "logout")) { _ in }
    }

    /// 一键登录：点一下 → 激活扩展 / 建隧道 → 拿到 AuthURL 立刻开浏览器。
    /// 用户不需要理解「扩展」「隧道」这些中间状态。
    func login() {
        guard Self.isInApplicationsFolder else {
            needsRelocation = true
            statusText = "扩展安装失败"
            error = "系统扩展只能从「应用程序」文件夹激活。当前 App 在 \(Self.currentLocationHint)，请点下方按钮搬到 /Applications 后重试。"
            return
        }
        needsRelocation = false
        autoOpenLogin = true

        // ① 已经拿到授权链接：直接开浏览器
        if !loginURL.isEmpty {
            openLoginPage()
            return
        }
        // ② 已经登录成功（backend=Running）：不要再去触发 StartLoginInteractive，
        //    那会把节点踢回 NeedsLogin 并重新生成授权链接。
        if backendState == "Running" {
            autoOpenLogin = false
            if !loginURL.isEmpty { openLoginPage() }
            else { statusText = "已登录"; log("已经是登录状态，无需重新授权") }
            return
        }
        // ③ 隧道已连但还没登录：让扩展重新生成 AuthURL，handleRuntime 会自动拉起浏览器
        if let session = manager?.connection as? NETunnelProviderSession,
           manager?.connection.status == .connected {
            log("请求交互式登录")
            try? session.sendProviderMessage(MergedTunnel.command("ts", "login")) { _ in }
            return
        }
        // ③ 隧道没起来：先确保扩展已安装且是最新版本（这一步会触发系统扩展升级），
        //    激活成功回调里会 configureAndStart()，连上后自动开浏览器
        log("确保扩展已就绪并建立隧道…")
        statusText = "正在准备登录…"
        enable()
    }

    /// 退出登录后重新授权（换账号 / 链接过期时用）
    func relogin() {
        logout()
        autoOpenLogin = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.login()
        }
    }

    /// 清掉本 App 在系统扩展数据库里的旧记录，再重新激活。
    /// 用于反复替换 /Applications 里的 App 之后 sysextd 报
    /// "Extension not found in App bundle" 的场景。
    func resetExtensionRecords() {
        guard Self.isInApplicationsFolder else {
            needsRelocation = true
            statusText = "扩展安装失败"
            error = "请先把 App 放到「应用程序」文件夹。"
            return
        }
        log("清理系统扩展数据库里的旧记录…")
        statusText = "正在清理扩展记录…"
        error = ""
        let ids = ["com.alick.sdp-proxy.ne", "com.alick.sdp-proxy.wg", Self.extensionID]
        let cleaner = SXRecordCleaner(identifiers: ids) { [weak self] failures in
            guard let self = self else { return }
            self.log("清理完成（失败 \(failures.count) 条）")
            self.recordCleaner = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.login()
            }
        }
        recordCleaner = cleaner
        cleaner.start()
    }

    private func clearRuntime() {
        backendState = ""
        selfIPs = []
        tailnet = ""
        loginURL = ""
        peers = []
        trafficText = ""
        lastRuntimeLine = ""
    }

    // MARK: - 运行时状态轮询

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
        try? session.sendProviderMessage(MergedTunnel.command("ts")) { [weak self] data in
            DispatchQueue.main.async { self?.handleRuntime(data) }
        }
    }

    private func handleRuntime(_ data: Data?) {
        guard let data = data,
              let st = try? JSONDecoder().decode(TSRuntimeStatus.self, from: data) else { return }
        backendState = st.backendState
        selfIPs = st.selfIPs
        tailnet = st.tailnet
        loginURL = st.authURL
        peers = st.peers

        let online = st.peers.filter { $0.online }.count
        let direct = st.peers.filter { $0.direct }.count
        trafficText = "RX \(Self.bytes(st.rxBytes)) / TX \(Self.bytes(st.txBytes))"

        let line = "[NET] backend=\(st.backendState) ip=\(selfIP) peers=\(st.peers.count) online=\(online) direct=\(direct) tailnet=\(st.tailnet)"
        // 在线节点的 IP 一并记下来，方便直接 ping 验证数据面是否通
        let onlineIPs = st.peers.filter { $0.online }.map { $0.ip }.filter { !$0.isEmpty }.sorted()
        if !onlineIPs.isEmpty, onlineIPs != lastOnlinePeerIPs {
            lastOnlinePeerIPs = onlineIPs
            log("在线节点: \(onlineIPs.prefix(6).joined(separator: ", "))")
        }
        if line != lastRuntimeLine {
            lastRuntimeLine = line
            log(line)
        }
        if !st.authURL.isEmpty, !(logs.last ?? "").hasSuffix("等待浏览器完成登录") {
            // 只在首次出现时提示，避免每 2s 刷屏
            log("需要登录: \(st.authURL) — 等待浏览器完成登录")
        }
        // 交互式登录：authURL 一出现就自动拉起浏览器（每个登录流程只自动打开一次）
        if autoOpenLogin, !st.authURL.isEmpty {
            autoOpenLogin = false
            log("自动打开授权页面")
            openLoginPage()
        }
    }

    private static func bytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
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
                self.clearRuntime()
                return
            }
            self.manager = mgr
            switch mgr.connection.status {
            case .connected:
                if !self.active {
                    self.log("隧道已连接")
                    self.lastRuntimeLine = ""
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
                self.clearRuntime()
            }
        }
    }

    // MARK: - VPN 配置下发

    func configureAndStart() {
        guard let cfg = activeConfig, cfg.valid else {
            log("配置无效：需要合法的 Control URL")
            statusText = "扩展已安装，请填写配置"
            return
        }
        log("启动配置: \(cfg.displayName) control=\(cfg.controlURL) mtu=\(cfg.mtu)")
        // authKey 留空 = 交互式登录：连上后拿到 authURL 就自动拉起浏览器
        autoOpenLogin = cfg.authKey.trimmingCharacters(in: .whitespaces).isEmpty
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, err in
            guard let self = self else { return }
            if let err = err { self.error = err.localizedDescription; return }
            let mgr = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionID
            }) ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.extensionID
            proto.serverAddress = URL(string: cfg.controlURL)?.host ?? cfg.controlURL
            // 只传扩展真正会读的键。
            // advertiseRoutes / exitNode / acceptRoutes / shieldIncoming 底层 tsnet
            // 引擎没有对应能力（tsnet.Server 无 AdvertiseRoutes、无 RouteAll），
            // 传过去也无人消费，已从界面移除。
            var providerConfig: [String: Any] = [
                "controlURL": cfg.controlURL,
                "authKey": cfg.authKey,
                "hostname": cfg.hostname,
                "routes": self.splitList(cfg.routes),
                "acceptDNS": cfg.acceptDNS,
            ]
            if let mtu = Int(cfg.mtu), mtu >= 576 { providerConfig["mtu"] = mtu }
            // 跟随 shared 当前状态：disable 路径先清掉 enabled，无条件 set(true)
            // 会把刚关掉的 Tailscale 又打开（关不掉的 bug）。
            if MergedTunnel.shared.features.contains("ts") {
                MergedTunnel.shared.set("ts", enabled: true, config: providerConfig)
            }
            proto.providerConfiguration = MergedTunnel.shared.providerConfiguration()
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "SDP"
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
            mgr.saveToPreferences { saveError in
                if let saveError = saveError {
                    self.error = saveError.localizedDescription
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
                            catch let e { self.error = e.localizedDescription; self.statusText = "启动失败" }
                        }
                    } else {
                        do {
                            try mgr.connection.startVPNTunnel()
                            self.statusText = "正在连接…"
                        } catch let e {
                            self.error = e.localizedDescription
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

extension TSManager: OSSystemExtensionRequestDelegate {
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
        NSLog("[TS] 安装失败: %@", error.localizedDescription)
        let msg = error.localizedDescription
        if msg.contains("/Applications") || msg.contains("Applications folder") {
            needsRelocation = true
            statusText = "扩展安装失败"
            self.error = "系统扩展只能从「应用程序」文件夹激活。当前 App 在 \(Self.currentLocationHint)，请点下方按钮搬到 /Applications 后重试。"
            return
        }
        // macOS 的「系统扩展数据库」里还留着旧版本记录时会报这个：
        // 数据库（/Library/SystemExtensions/db.plist）按 bundle ID 记着 App 和它的扩展列表，
        // 换了新版 App 之后旧记录不会自动刷新，sysextd 就找不到新加的扩展。
        // 重启一次会清掉所有 "waiting to uninstall on reboot" 的旧记录并重新扫描。
        if msg.contains("Extension not found in App bundle") {
            statusText = "扩展安装失败"
            self.error = "系统里还留着旧版本的系统扩展记录（sysextd 找不到新扩展）。重启一次 Mac 后再点登录即可恢复。"
            return
        }
        self.error = msg
        statusText = "扩展安装失败"
    }
}

// MARK: - 清理系统扩展数据库里的旧记录

/// 系统扩展数据库（/Library/SystemExtensions/db.plist）按 bundle ID 记住「哪个 App 装了哪些扩展」。
/// 反复替换 /Applications 里的 App 之后，旧记录会和实际 bundle 内容对不上，
/// sysextd 就会报 "Extension not found in App bundle"。
///
/// `deactivationRequest` 只有**宿主 App 自己**能发，而且不需要 root，
/// 所以用它把旧记录删掉，下次激活就是干净的首次安装。
final class SXRecordCleaner: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    private var pending: [String] = []
    private var failed: [String] = []
    private let onDone: ([String]) -> Void

    init(identifiers: [String], onDone: @escaping ([String]) -> Void) {
        self.pending = identifiers
        self.onDone = onDone
        super.init()
    }

    func start() { next() }

    private func next() {
        guard !pending.isEmpty else {
            let f = failed
            onDone(f)
            return
        }
        let id = pending.removeFirst()
        let req = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: id, queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        next()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        failed.append(error.localizedDescription)
        next()
    }
}
