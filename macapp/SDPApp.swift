import SwiftUI
import AppKit
import WebKit

// SDP 代理 - MenuBarExtra (SwiftUI) 版本

@main
struct SDPApp: App {
    @NSApplicationDelegateAdaptor(SDPAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.state == "connected"
                  ? "network.badge.shield.half.filled" : "network.slash")
        }
        .menuBarExtraStyle(.window)
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
    @Published var qrTS: Int64 = 0
    @Published var qrReady = false
    @Published var loginError = ""
    @Published var logs: [String] = []
    @Published var logsText = ""
    @Published var proxyEnabled = false
    @Published var showLogs = false
    @Published var lastError = ""
    @Published var pulsePhase = false

    private var timer: Timer?
    private var pulseTimer: Timer?
    private var proxyTask: Process?
    private var quitting = false
    private var proxyCheckBusy = false
    private var proxyInFlight = false

    let home = NSHomeDirectory()
    var configPath: String { home + "/.sdp-proxy/config.json" }
    var logPath: String { home + "/.sdp-proxy/app.log" }
    var proxyBinary: String {
        Bundle.main.bundlePath + "/Contents/Resources/sdp-proxy"
    }

    init() {
        AppModel.shared = self
        DispatchQueue.main.async {
            NSApp.appearance = nil // 跟随系统亮暗色
        }
        ensureDirs()
        startProxy()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.state == "connected" { self.pulsePhase.toggle() }
        }
        refreshSystemProxyState()
    }

    // MARK: - 后端进程

    private func ensureDirs() {
        try? FileManager.default.createDirectory(atPath: home + "/.sdp-proxy", withIntermediateDirectories: true)
    }

    func startProxy() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: proxyBinary)
        p.arguments = ["-config", configPath]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.quitting else { return }
                self.lastError = "代理进程退出，正在重启…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if !self.quitting { self.startProxy() }
                }
            }
        }
        do {
            try p.run()
            proxyTask = p
        } catch {
            lastError = "启动代理失败: \(error.localizedDescription)"
        }
    }

    func uiAddress() -> String {
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ui = obj["ui_listen"] as? String, !ui.isEmpty {
            return ui.contains(":") ? ui : ui + ":28181"
        }
        return "127.0.0.1:28181"
    }

    var apiBase: String { "http://" + uiAddress() }

    // MARK: - 刷新状态

    func refresh() {
        getJSON("/api/status") { [weak self] s in
            guard let self = self else { return }
            self.state = (s["state"] as? String) ?? "login_required"
            self.username = (s["username"] as? String) ?? ""
            self.sessionOK = (s["session_ok"] as? Bool) ?? false
            self.resourceCount = (s["resource_count"] as? Int) ?? 0
        }
        getJSON("/api/login") { [weak self] l in
            guard let self = self else { return }
            let ts = (l["ts"] as? Int64) ?? Int64((l["ts"] as? Int) ?? 0)
            self.qrTS = ts
            self.qrReady = (l["qr_ready"] as? Bool) ?? false
            self.loginError = (l["error"] as? String) ?? ""
        }
        if state == "connected" {
            getJSON("/api/resources") { [weak self] r in
                guard let self = self else { return }
                let list = (r["resources"] as? [[String: Any]]) ?? []
                self.resources = list.map {
                    ResItem(domain: ($0["domain"] as? String) ?? "",
                            resid: ($0["resid"] as? String) ?? "",
                            ports: ($0["ports"] as? String) ?? "")
                }
            }
        }
        if showLogs { fetchLogs() }
        if !proxyInFlight { refreshSystemProxyState() }
    }

    func fetchLogs() {
        getJSON("/api/logs") { [weak self] d in
            guard let self = self else { return }
            let lines = (d["lines"] as? [String]) ?? []
            self.logs = lines
            self.logsText = lines.joined(separator: "\n")
        }
    }

    private func getJSON(_ path: String, _ done: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: apiBase + path) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async { done(obj) }
        }.resume()
    }

    // MARK: - 动作

    func post(_ path: String, then: (() -> Void)? = nil) {
        guard let url = URL(string: apiBase + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.refresh()
                then?()
            }
        }.resume()
    }

    func relogin() { post("/api/relogin") }
    func refreshQR() { post("/api/login/refresh") }

    // MARK: - 系统代理

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
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return (-1, "timeout")
        }
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
        proxyInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let on = self.systemProxyEnabled()
            DispatchQueue.main.async {
                self.proxyEnabled = on
                self.proxyCheckBusy = false
                self.proxyInFlight = false
            }
        }
    }

    func toggleSystemProxy() {
        guard let svc = activeService() else {
            lastError = "未找到活动网络服务"
            return
        }
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

    // MARK: - 退出

    func quit() {
        quitting = true
        timer?.invalidate()
        pulseTimer?.invalidate()
        if systemProxyEnabled(), let svc = activeService() {
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
        }
        proxyTask?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - 应用退出清理（Cmd+Q / 系统退出时也要还原系统代理）

final class SDPAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        guard let model = AppModel.shared else { return }
        model.shutdownSynchronously()
    }
}

extension AppModel {
    /// 同步清理：关闭系统代理 + 结束后端进程（不依赖异步回调）
    func shutdownSynchronously() {
        quitting = true
        if let svc = activeService(), systemProxyEnabled() {
            _ = run("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
            _ = run("/usr/sbin/networksetup", ["-setautoproxyurl", svc, ""])
        }
        proxyTask?.terminate()
    }
}
