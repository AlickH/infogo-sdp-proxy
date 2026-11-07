import SwiftUI
import AppKit
import WebKit

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
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
                iconButton("arrow.clockwise", help: "刷新二维码", visible: model.state == "scanning") {
                    model.refreshQR()
                }
                iconButton("arrow.triangle.2.circlepath", help: "重新登录",
                           visible: model.state == "connected" || model.state == "offline") {
                    model.relogin()
                }
                iconButton("doc.text", help: "日志", visible: true) {
                    model.showLogs.toggle()
                }
                iconButton("network", help: model.proxyEnabled ? "取消系统代理" : "设为系统代理",
                           visible: true, active: model.proxyEnabled) {
                    model.toggleSystemProxy()
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

    private var subtitle: String {
        switch model.state {
        case "connected": return "共 \(model.resourceCount) 个可用资源"
        case "offline": return "会话已断开"
        case "scanning": return ""
        default: return "零信任 SOCKS5 · 无需接管系统网络"
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
            infoRow("PAC", "http://\(model.uiAddress())/proxy.pac")
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
        QRContainer(url: model.qrURL, onScanned: model.onScanned)
            .frame(width: 300, height: 352)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    private var checkingView: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在认证并安检…").font(.system(size: 12))
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var loginRequiredView: some View {
        VStack(spacing: 10) {
            Text("需要登录").font(.system(size: 14, weight: .medium))
            Text("请点击下方按钮，用「中建通」扫码").font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 36, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
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
