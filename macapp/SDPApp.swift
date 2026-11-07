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
    @Published var proxyEnabled = false
    @Published var showLogs = false
    @Published var lastError = ""

    let engine: Engine
    private let server: ProxyServer
    private var proxyTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var proxyCheckBusy = false

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
                DispatchQueue.main.async { self?.syncFromEngine() }
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
        }

        proxyTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshSystemProxyState()
        }
        refreshSystemProxyState()
    }

    func syncFromEngine() {
        state = engine.state
        username = engine.username
        sessionOK = engine.sessionOK
        qrURL = engine.qrURL
        loginError = engine.loginError
        resources = engine.store.snapshot().map {
            ResItem(domain: $0.pattern, resid: $0.resid, ports: $0.ports)
        }
        resourceCount = resources.count
        logsText = engine.logs.joined(separator: "\n")
    }

    func relogin() {
        Task { @MainActor in
            // 与 Go 版一致：退出登录时先关闭系统代理，避免断网
            if proxyEnabled, let svc = activeService() {
                _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
                refreshSystemProxyState()
            }
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

    func quit() {
        proxyTimer?.invalidate()
        server.stop()
        if systemProxyEnabled(), let svc = activeService() {
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
        }
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

    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 4) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (-1, "timeout") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func activeService() -> String? {
        let (code, out) = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard code == 0 else { return nil }
        for line in out.split(separator: "\n") {
            let svc = line.trimmingCharacters(in: .whitespaces)
            if svc.isEmpty || svc.hasPrefix("*") || svc.contains("An asterisk") { continue }
            let (c2, info) = run("/usr/sbin/networksetup", ["-getinfo", svc])
            if c2 == 0 && info.contains("IP address:") { return svc }
        }
        return nil
    }

    func systemProxyEnabled() -> Bool {
        guard let svc = activeService() else { return false }
        let (_, out) = run("/usr/sbin/networksetup", ["-getautoproxyurl", svc])
        return out.contains("proxy.pac") && out.contains("Enabled: Yes")
    }

    func refreshSystemProxyState() {
        guard !proxyCheckBusy else { return }
        proxyCheckBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let on = self.systemProxyEnabled()
            DispatchQueue.main.async {
                self.proxyEnabled = on
                self.proxyCheckBusy = false
            }
        }
    }

    func toggleSystemProxy() {
        guard let svc = activeService() else { lastError = "未找到活动网络服务"; return }
        let pac = "http://" + uiAddress() + "/proxy.pac"
        if proxyEnabled {
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
        } else {
            _ = run("/usr/sbin/networksetup", ["-setautoproxyurl", svc, pac])
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "on"])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshSystemProxyState()
        }
    }

    func shutdownSynchronously() {
        server.stop()
        if let svc = activeService(), systemProxyEnabled() {
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
            _ = run("/usr/sbin/networksetup", ["-setautoproxyurl", svc, ""])
        }
    }
}

// MARK: - 应用退出清理

final class SDPAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared?.shutdownSynchronously()
    }
}
