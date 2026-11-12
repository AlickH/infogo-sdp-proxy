import SwiftUI
import AppKit
import WebKit

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar.padding(.bottom, 10)
            header.padding(.bottom, 10)
            Divider()
            currentTab
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            logsPane
            footerSwitch
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var currentTab: some View {
        switch model.tab {
        case .sdp: sdpTab
        case .wireguard: wireGuardTab
        case .tailscale: tailscaleTab
        }
    }

    private var headerTitle: String {
        switch model.tab {
        case .sdp: return "SDP 代理"
        case .wireguard: return "WireGuard"
        case .tailscale: return "Tailscale"
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            headerIcon
            HStack(spacing: 6) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(headerBadgeText)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(headerBadgeColor.opacity(0.16))
                    .foregroundColor(headerBadgeColor)
                    .clipShape(Capsule())
            }
            Spacer()
            HStack(spacing: 6) {
                if model.tab == .sdp {
                    iconButton("list.bullet.rectangle", help: "可用资源",
                               visible: !model.resources.isEmpty, active: showResources) {
                        withAnimation(.snappy(duration: 0.24)) {
                            showLogsPane = false
                            model.showLogs = false
                            showResources.toggle()
                        }
                    }
                    iconButton("arrow.clockwise", help: "刷新二维码",
                               visible: model.state == "scanning" || model.state == "login_required") {
                        model.refreshQR()
                    }
                    iconButton("arrow.triangle.2.circlepath", help: "重新登录",
                               visible: model.state == "connected" || model.state == "offline") {
                        model.relogin()
                    }
                }
                if model.tab == .wireguard {
                    iconButton("square.and.arrow.down", help: "导入 .conf 配置文件", visible: true) {
                        importWGPanel()
                    }
                    iconButton("plus", help: "新建配置", visible: true) {
                        model.newWGConfigDraft()
                        showWGSheet = true
                    }
                }
                if model.tab == .tailscale {
                    if !model.tsNeedsRelocation,
                       model.tsBackendState == "NeedsLogin" || !model.tsLoginURL.isEmpty {
                        iconButton(model.tsLoginURL.isEmpty ? "person.badge.key" : "safari",
                                   help: model.tsLoginURL.isEmpty ? "登录 Tailscale" : "打开 Tailscale 登录链接",
                                   visible: true) {
                            if model.tsLoginURL.isEmpty { model.loginTS() } else { model.openTSLogin() }
                        }
                    }
                    // 配置项极少（多数默认值即可用），不再做「多配置列表」，
                    // 收成一个「高级设置」入口，只保留网页控制台改不了的本地项。
                    iconButton("gearshape", help: "高级设置", visible: true) {
                        if let id = model.tsActiveID { model.editTSDraft(id) }
                        else { model.newTSConfigDraft() }
                        showTSSheet = true
                    }
                }
                iconButton("doc.text", help: "日志", visible: true, active: showLogsPane) {
                    withAnimation(.snappy(duration: 0.24)) {
                        showResources = false
                        showLogsPane.toggle()
                        model.showLogs = showLogsPane
                    }
                    if showLogsPane {
                        // 动画结束后再刷新内容，避免刷新打断高度动画
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            model.syncLogsForCurrentTab()
                        }
                    }
                }
                iconButton("power", help: "退出", visible: true) {
                    model.quit()
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.snappy(duration: 0.16)) { model.tab = t }
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(model.tab == t ? .primary : .secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)
                        .background {
                            if model.tab == t {
                                Capsule()
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear)
            } else {
                Capsule().fill(Color.primary.opacity(0.07))
            }
        }
        .modifier(GlassTabBackground())
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch model.tab {
        case .sdp:
            let connected = model.state == "connected"
            symbolIcon(connected ? "network.badge.shield.half.filled" : "network.slash",
                       active: connected)
        case .wireguard:
            symbolIcon(model.wgActive ? "point.3.filled.connected.trianglepath.dotted"
                                      : "point.3.connected.trianglepath.dotted",
                       active: model.wgActive)
        case .tailscale:
            symbolIcon(model.tsActive ? "link.circle.fill" : "link.circle",
                       active: model.tsActive)
        }
    }

    @ViewBuilder
    private func symbolIcon(_ name: String, active: Bool) -> some View {
        if #available(macOS 15.0, *) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24, height: 24)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
        } else if #available(macOS 14.0, *) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24, height: 24)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24, height: 24)
        }
    }

    private var headerBadgeText: String {
        switch model.tab {
        case .wireguard:
            if model.wgActive { return "已连接" }
            if model.wgConfigs.isEmpty { return "无配置" }
            return "未连接"
        case .tailscale:
            if model.tsBackendState == "NeedsLogin" || !model.tsLoginURL.isEmpty { return "待登录" }
            if model.tsActive { return model.tsBackendState.isEmpty ? "已连接" : model.tsBackendState }
            if model.tsConfigs.isEmpty { return "无配置" }
            return "未连接"
        case .sdp:
            return badgeText
        }
    }

    private var headerBadgeColor: Color {
        switch model.tab {
        case .wireguard:
            return model.wgActive ? .green : .secondary
        case .tailscale:
            if model.tsBackendState == "NeedsLogin" || !model.tsLoginURL.isEmpty { return .orange }
            if model.tsActive { return .green }
            return .secondary
        case .sdp:
            return badgeColor
        }
    }

    @ViewBuilder
    private func glassCircle<V: View>(_ content: V) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private func iconButton(_ symbol: String, help: String, visible: Bool, active: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if visible {
                Button(action: action) {
                    glassCircle(
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 26, height: 26)
                    )
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundColor(active ? .accentColor : .primary)
                .help(help)
            }
        }
    }

    private var badgeText: String {
        switch model.state {
        case "connected": return "已连接"
        case "scanning": return "等待扫码"
        case "checking": return "验证中"
        case "offline": return "已掉线"
        default: return "未登录"
        }
    }

    private var badgeColor: Color {
        switch model.state {
        case "connected": return .green
        case "scanning", "checking": return .blue
        case "offline": return .red
        default: return .secondary
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case "connected":
            connectedView
        case "scanning":
            scanningView
        case "checking":
            checkingView
        case "offline":
            offlineView
        default:
            loginRequiredView
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("账号", model.username.isEmpty ? "-" : model.username)
            infoRow("会话", model.sessionOK ? "正常" : "异常")
        }
    }

    private var scanningView: some View {
        VStack(spacing: 8) {
            QRContainer(url: model.qrURL, onScanned: model.onScanned)
                .frame(width: 300, height: 352)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            errorBanner
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if !model.loginError.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10)).foregroundColor(.red)
                Text(model.loginError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private var checkingView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在认证…").font(.system(size: 12))
            }
            errorBanner
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var offlineView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26)).foregroundColor(.orange)
            Text("连接已断开").font(.system(size: 14, weight: .medium))
            Text("会话已过期，需要重新扫码登录").font(.system(size: 11)).foregroundColor(.secondary)
            errorBanner
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var loginRequiredView: some View {
        VStack(spacing: 10) {
            Text("需要登录").font(.system(size: 14, weight: .medium))
            Text("用「中建通」扫描二维码即可登录").font(.system(size: 11)).foregroundColor(.secondary)
            Button("生成二维码") { model.refreshQR() }
                .buttonStyle(.borderless)
            errorBanner
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 36, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - SDP 标签页

    private var sdpTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            resourcePane
        }
    }

    // MARK: - WireGuard 标签页

    @State private var showWGSheet = false
    @State private var showTSSheet = false
    @State private var showResources = false
    @State private var showLogsPane = false

    private var wireGuardTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.wgConfigs.isEmpty {
                Text("暂无配置，点右上角 + 新建或导入 .conf")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.wgConfigs) { c in
                            wgConfigRow(c)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            if !model.wgError.isEmpty {
                Text(model.wgError).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
            }

        }
        .sheet(isPresented: $showWGSheet) {
            WGEditSheet(
                draft: $model.wgDraft,
                onSave: {
                    model.saveWGDraft()
                    showWGSheet = false
                },
                onCancel: { showWGSheet = false }
            )
        }
    }

    private func wgConfigRow(_ c: WGConfig) -> some View {
        let selected = c.id == model.wgActiveID
        return HStack(spacing: 6) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(selected ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.displayName).font(.system(size: 11))
                if !c.endpoint.isEmpty {
                    Text(c.endpoint).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                model.editWGDraft(c.id)
                showWGSheet = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("编辑配置")
            Button {
                model.selectWG(c.id)
                model.deleteActiveWG()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("删除配置")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectWG(c.id) }
    }

    private func importWGPanel() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["conf", "txt"]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        if !model.importWG(text: text, name: url.deletingPathExtension().lastPathComponent) {
            model.wgError = "配置文件解析失败（缺少 PrivateKey / PublicKey / Endpoint）"
        }
    }

    // MARK: - Tailscale 标签页

    private var tailscaleTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                infoRow("状态", tsStateText)
                infoRow("本机", model.tsSelfIP)
                if !model.tsTailnet.isEmpty { infoRow("网络", model.tsTailnet) }
                if !model.tsTrafficText.isEmpty { infoRow("流量", model.tsTrafficText) }
                if model.tsNeedsRelocation {
                    relocationCard
                } else if model.tsBackendState == "NeedsLogin" || !model.tsLoginURL.isEmpty || !model.tsActive {
                    loginButton
                }
            }

            if !model.tsPeers.isEmpty {
                Text("节点  \(model.tsPeers.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.tsPeers) { p in tsPeerRow(p) }
                    }
                }
                .frame(maxHeight: 88)
            }

            if !model.tsError.isEmpty {
                Text(model.tsError).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
            }
        }
        .sheet(isPresented: $showTSSheet) {
            TSEditSheet(
                draft: $model.tsDraft,
                onSave: {
                    model.saveTSDraft()
                    showTSSheet = false
                },
                onCancel: { showTSSheet = false }
            )
        }
    }

    private var tsStateText: String {
        if model.tsNeedsRelocation { return "扩展安装失败" }
        if !model.tsLoginURL.isEmpty { return "等待浏览器完成登录" }
        if !model.tsBackendState.isEmpty { return model.tsBackendState }
        return model.tsStatus
    }

    /// 一键登录按钮：点一下就开浏览器（必要时自动激活扩展、建隧道、等 AuthURL）
    private var loginButton: some View {
        let hasURL = !model.tsLoginURL.isEmpty
        return Button {
            if hasURL { model.openTSLogin() } else { model.loginTS() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasURL ? "safari.fill" : "person.badge.key.fill")
                    .font(.system(size: 11))
                Text(hasURL ? "在浏览器中完成授权" : "登录 Tailscale")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(hasURL ? .blue : .accentColor)
    }

    /// App 不在 /Applications：系统扩展激活的硬性前置条件没满足
    private var relocationCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                Text("App 不在「应用程序」文件夹，系统扩展无法激活")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(TSManager.currentLocationHint)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                model.relocateTS()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.app.fill").font(.system(size: 11))
                    Text("安装到「应用程序」并重启")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.10)))
    }

    private func tsPeerRow(_ p: TSPeer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: p.online ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundColor(p.online ? .green : .secondary)
            Text(p.name.isEmpty ? p.ip : p.name)
                .font(.system(size: 10))
                .lineLimit(1)
            Text(p.ip)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Text(p.direct ? "直连" : (p.online ? "中继" : "离线"))
                .font(.system(size: 9))
                .foregroundColor(p.direct ? .green : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func tsConfigRow(_ c: TSConfig) -> some View {
        let selected = c.id == model.tsActiveID
        return HStack(spacing: 6) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(selected ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.displayName).font(.system(size: 11))
                Text("\(c.controlURL) · \(c.loginMode)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.editTSDraft(c.id)
                showTSSheet = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("编辑配置")
            Button {
                model.selectTS(c.id)
                model.deleteActiveTS()
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("删除配置")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectTS(c.id) }
    }

    // MARK: - 底部开关（固定面板底部）

    @ViewBuilder
    private var footerSwitch: some View {
        switch model.tab {
        case .sdp:
            if model.state == "connected" {
                Divider().padding(.top, 10)
                HStack(spacing: 6) {
                    Text("全局接管").font(.system(size: 11))
                    Text(model.neActive ? "所有内网流量经 SDP 隧道" : "通过 SOCKS5 代理访问内网")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.neActive },
                        set: { _ in model.toggleNE() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.top, 10)
            }
        case .wireguard:
            Divider().padding(.top, 10)
            HStack(spacing: 6) {
                Text("连接").font(.system(size: 11))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.wgActive },
                    set: { _ in model.toggleWG() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.wgConfigs.isEmpty)
            }
            .padding(.top, 10)
        case .tailscale:
            Divider().padding(.top, 10)
            HStack(spacing: 6) {
                Text("连接").font(.system(size: 11))
                Text(model.tsActive ? "100.64.0.0/10" : "Tailscale mesh")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                if model.tsActive {
                    Button("退出登录") { model.logoutTS() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                }
                Toggle("", isOn: Binding(
                    get: { model.tsActive },
                    set: { _ in model.toggleTS() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - 底部窗格

    private var logText: String {
        switch model.tab {
        case .sdp: return model.logsText
        case .wireguard: return model.wgLogsText
        case .tailscale: return model.tsLogsText
        }
    }

    private var logsTitle: String {
        switch model.tab {
        case .sdp: return "运行日志"
        case .wireguard: return "WireGuard 日志"
        case .tailscale: return "Tailscale 日志"
        }
    }

    private var logsPane: some View {
        ExpandablePane(
            expanded: showLogsPane,
            title: logsTitle,
            onClose: {
                withAnimation(.snappy(duration: 0.24)) {
                    showLogsPane = false
                    model.showLogs = false
                }
            }
        ) {
            Text(logText.isEmpty ? "（暂无日志）" : logText)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var resourcePane: some View {
        ExpandablePane(
            expanded: showResources,
            title: "可用资源  \(model.resources.count)",
            onClose: {
                withAnimation(.snappy(duration: 0.24)) { showResources = false }
            }
        ) {
            Text(resourceText)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var resourceText: String {
        model.resources.map { r in
            r.ports.isEmpty ? "\(r.domain) → \(r.resid)" : "\(r.domain) → \(r.resid)  \(r.ports)"
        }.joined(separator: "\n")
    }
}

// MARK: - 二维码 WebView（加载本机包装页，页面 JS 完成扫码流程）

struct PanelStatusIcon: View {
    let state: String
    private var connected: Bool { state == "connected" }
    private var symbol: String {
        connected ? "checkmark.shield.fill" : "shield.slash.fill"
    }

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .symbolEffect(.pulse, options: .repeating, isActive: connected)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
        } else if #available(macOS 14.0, *) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .symbolEffect(.pulse, options: .repeating, isActive: connected)
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
}

/// 统一的展开/收起窗格：日志与可用资源共用
struct ExpandablePane<Content: View>: View {
    var expanded: Bool
    var title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    static var height: CGFloat { 176 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.height, alignment: .top)
        .clipped()
        .frame(height: expanded ? Self.height : 0, alignment: .top)
        .clipped()
        .opacity(expanded ? 1 : 0)
        .padding(.top, expanded ? 12 : 0)
    }
}

struct GlassTabBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
        }
    }
}

// MARK: - WireGuard 配置编辑 Sheet

struct WGEditSheet: View {
    @Binding var draft: WGConfig
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WireGuard 配置").font(.system(size: 13, weight: .semibold))
            field("显示名称", $draft.name, placeholder: "列表里展示的名字")
            field("私钥", $draft.privateKey)
            HStack(spacing: 6) {
                Text("公钥").font(.system(size: 10)).foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
                Text(draft.publicKey ?? "（私钥无效）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(draft.publicKey == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
            }
            field("地址", $draft.address, placeholder: "10.0.0.2/32")
            field("DNS", $draft.dns, placeholder: "1.1.1.1")
            field("对端公钥", $draft.peerPublicKey)
            field("Endpoint", $draft.endpoint, placeholder: "host:51820")
            field("AllowedIPs", $draft.allowedIPs, placeholder: "0.0.0.0/0")
            field("Keepalive", $draft.keepalive, placeholder: "25")
            field("MTU", $draft.mtu, placeholder: "1420")
            Toggle("按需连接（On-Demand，Ethernet / Wi-Fi 自动连接）", isOn: $draft.onDemand)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 440)
    }

    private func field(_ label: String, _ value: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
    }
}

// MARK: - Tailscale 配置编辑 Sheet

struct TSEditSheet: View {
    @Binding var draft: TSConfig
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tailscale 高级设置").font(.system(size: 13, weight: .semibold))
            Text("以下都是网页控制台改不了的本地项。设备名、MagicDNS 总开关、路由审批请到 tailscale.com/admin 操作。")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            field("Control URL", $draft.controlURL, placeholder: "https://controlplane.tailscale.com")
            field("Auth Key", $draft.authKey, placeholder: "留空则交互式登录（tskey-...）")
            field("捕获路由", $draft.routes, placeholder: "100.64.0.0/10")
            field("MTU", $draft.mtu, placeholder: "1280")
            Group {
                Toggle("使用 MagicDNS", isOn: $draft.acceptDNS)
                Toggle("按需连接（On-Demand，Ethernet / Wi-Fi 自动连接）", isOn: $draft.onDemand)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 10))
            Text("Control URL 可指向自建 Headscale；Auth Key 留空时，连接后需在浏览器完成 SSO 登录。")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("广播子网 / Exit Node / Shield incoming 暂不支持——底层 tsnet 引擎没有这些能力，需换用完整 tailscaled 才能实现。")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") { onSave() }
            }
        }
        .frame(width: 420)
        .padding(4)
    }

    private func field(_ label: String, _ value: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 88, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
    }
}

