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
            Group {
                if model.tab == .sdp {
                    sdpTab
                } else {
                    wireGuardTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            logsPane
            footerSwitch
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            headerIcon
            HStack(spacing: 6) {
                Text(model.tab == .sdp ? "SDP 代理" : "WireGuard")
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
                        showLogsPane = false
                        model.showLogs = false
                        showResources.toggle()
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
                iconButton("doc.text", help: "日志", visible: true, active: showLogsPane) {
                    showResources = false
                    showLogsPane.toggle()
                    model.showLogs = showLogsPane
                    if showLogsPane {
                        // 动画结束后再刷新内容，避免刷新打断高度动画
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            model.syncFromEngine(); model.syncWGLogs()
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
        if model.tab == .sdp {
            let connected = model.state == "connected"
            symbolIcon(connected ? "network.badge.shield.half.filled" : "network.slash",
                       active: connected)
        } else {
            symbolIcon(model.wgActive ? "point.3.filled.connected.trianglepath.dotted"
                                      : "point.3.connected.trianglepath.dotted",
                       active: model.wgActive)
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
        if model.tab == .wireguard {
            if model.wgActive { return "已连接" }
            if model.wgConfigs.isEmpty { return "无配置" }
            return "未连接"
        }
        return badgeText
    }

    private var headerBadgeColor: Color {
        if model.tab == .wireguard {
            return model.wgActive ? .green : .secondary
        }
        return badgeColor
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

    // MARK: - 底部开关（固定面板底部）

    @ViewBuilder
    private var footerSwitch: some View {
        if model.tab == .sdp {
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
        } else {
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
        }
    }

    // MARK: - 底部窗格

    private var logText: String {
        model.tab == .wireguard ? model.wgLogsText : model.logsText
    }

    private var logsPane: some View {
        ExpandablePane(
            expanded: showLogsPane,
            title: model.tab == .wireguard ? "WireGuard 日志" : "运行日志",
            onClose: { showLogsPane = false; model.showLogs = false }
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
            onClose: { withAnimation(.snappy(duration: 0.24)) { showResources = false } }
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
        .animation(.snappy(duration: 0.24), value: expanded)
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

