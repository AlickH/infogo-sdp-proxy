import SwiftUI
import AppKit
import WebKit

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $model.tab) {
                ForEach(PanelTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            Group {
                if model.tab == .sdp {
                    sdpTab
                } else {
                    wireGuardTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if model.showLogs { logsView }
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            PanelStatusIcon(state: model.state)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("SDP 代理").font(.system(size: 15, weight: .semibold))
                Text(badgeText)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.16))
                    .foregroundColor(badgeColor)
                    .clipShape(Capsule())
            }
            Spacer()
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", help: "刷新二维码",
                           visible: model.state == "scanning" || model.state == "login_required") {
                    model.refreshQR()
                }
                iconButton("arrow.triangle.2.circlepath", help: "重新登录",
                           visible: model.state == "connected" || model.state == "offline") {
                    model.relogin()
                }
                iconButton("doc.text", help: "日志", visible: true) {
                    model.showLogs.toggle()
                    if model.showLogs { model.syncFromEngine() }
                }
                iconButton("power", help: "退出", visible: true) {
                    model.quit()
                }
            }
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
            infoRow("SOCKS", "127.0.0.1:11095")
            infoRow("规则", "http://\(model.uiAddress())/surge.list")
            if !model.resources.isEmpty {
                Text("可用资源").font(.system(size: 11)).foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.resources.prefix(30)) { r in
                            HStack(spacing: 6) {
                                Text(r.domain).font(.system(size: 10.5, design: .monospaced))
                                Text("→ \(r.resid)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                if !r.ports.isEmpty {
                                    Text(r.ports).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("全局接管").font(.system(size: 11))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.neActive },
                    set: { _ in model.toggleNE() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.sessionOK && model.state != "connected")
            }
            HStack(spacing: 4) {
                Circle()
                    .fill(model.neActive ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(model.neStatus).font(.system(size: 10)).foregroundColor(.secondary)
                Text(model.neActive ? "所有内网流量经 SDP 隧道" : "通过 SOCKS 代理访问内网")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
            }
            Divider()
            content
        }
    }

    // MARK: - WireGuard 标签页

    private var wireGuardTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    if model.wgConfigs.isEmpty {
                        Text("暂无配置")
                    } else {
                        ForEach(model.wgConfigs) { c in
                            Button(c.displayName) { model.selectWG(c.id) }
                        }
                    }
                } label: {
                    Text(model.wgConfigs.first(where: { $0.id == model.wgActiveID })?.displayName ?? "暂无配置")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 200, alignment: .leading)

                Spacer()

                Button {
                    importWGPanel()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("导入 .conf 配置文件")

                Button {
                    model.deleteActiveWG()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除当前配置")
                .disabled(model.wgConfigs.isEmpty)

                Button {
                    model.wgDraft = WGConfig()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建配置")
                .disabled(model.wgActiveID != nil && !model.wgDraft.valid)
            }

            HStack {
                Toggle("连接", isOn: Binding(
                    get: { model.wgActive },
                    set: { _ in model.toggleWG() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Text(model.wgStatus)
                    .font(.system(size: 10))
                    .foregroundColor(model.wgActive ? .green : .secondary)
            }

            if !model.wgError.isEmpty {
                Text(model.wgError).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
            }

            Divider()

            wgField("名称", $model.wgDraft.name, placeholder: "可选，默认用 Endpoint")
            wgField("私钥", $model.wgDraft.privateKey)
            wgField("地址", $model.wgDraft.address, placeholder: "10.0.0.2/32")
            wgField("DNS", $model.wgDraft.dns, placeholder: "1.1.1.1")
            wgField("对端公钥", $model.wgDraft.peerPublicKey)
            wgField("Endpoint", $model.wgDraft.endpoint, placeholder: "host:51820")
            wgField("AllowedIPs", $model.wgDraft.allowedIPs, placeholder: "0.0.0.0/0")
            wgField("Keepalive", $model.wgDraft.keepalive, placeholder: "25")
            wgField("MTU", $model.wgDraft.mtu, placeholder: "1420")

            HStack {
                Spacer()
                Button("保存配置") { model.saveWGDraft() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        }
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

    private func wgField(_ label: String, _ value: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
    }

    // MARK: - 底部

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("运行日志").font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    model.showLogs = false
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            ScrollView {
                Text(model.logsText.isEmpty ? "（暂无日志）" : model.logsText)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
