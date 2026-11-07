import Foundation
import Combine

/// 纯 Swift 核心引擎：登录 / 会话 / 资源策略 / 状态机
final class Engine: ObservableObject {
    @Published var state = "login_required"   // login_required|scanning|checking|connected|offline
    @Published var username = ""
    @Published var logs: [String] = []
    @Published var resourceCount = 0
    @Published var sessionOK = false
    @Published var loginError = ""
    @Published var qrURL = ""
    @Published var qrTS: Int64 = 0

    let cfgPath: String
    private(set) var cfg: SDPConfig
    private(set) var api: SDPApiClient
    let store = RuleStore()
    private(set) var token: String?
    private var serverInfo: [String: Any]?

    private var pollTask: Task<Void, Never>?
    private var sessionTimer: Timer?
    private var policyTimer: Timer?
    private let logLock = NSLock()

    init(cfgPath: String = SDPConfig.defaultPath) {
        self.cfgPath = cfgPath
        self.cfg = (try? SDPConfig.load(path: cfgPath)) ?? SDPConfig(
            gateway: "122.191.10.77:27442,122.191.10.77:37442,122.191.10.77:47442",
            serverName: "sdp.cscec5b.com.cn",
            serverBase: "https://sdp.cscec5b.com.cn:17441",
            deviceID: "888499",
            token: nil, tokenTimestamp: nil,
            listen: "127.0.0.1:11095", httpListen: "127.0.0.1:11096",
            uiListen: "127.0.0.1:28181",
            resources: nil, learnedResources: nil, directDomains: nil)
        self.api = SDPApiClient(base: cfg.serverBase, token: cfg.token)
        self.token = (cfg.token?.isEmpty == false) ? cfg.token : nil
        api.token = token
    }

    func log(_ s: String) {
        let line = "\(Self.df.string(from: Date())) \(s)"
        logLock.lock()
        logs.append(line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        logLock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .engineLog, object: line) }
    }

    static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    // MARK: - 启动

    func start() async {
        if token != nil {
            let ok = await checkSession()
            if ok {
                state = "connected"
                sessionOK = true
                await fetchPolicy()
                startTimers()
                log("[会话] 已连接")
                return
            }
            log("[会话] token 失效，需要重新扫码")
        }
        state = "login_required"
    }

    private func startTimers() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.checkSession() }
        }
        policyTimer?.invalidate()
        policyTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.fetchPolicy() }
        }
    }

    // MARK: - 登录

    /// 准备登录页并返回二维码 URL
    func beginLogin() async -> String? {
        loginError = ""
        do {
            let info = try await api.serverInfo()
            serverInfo = info
            let url = makeQRURL(info: info)
            state = "scanning"
            await startPoll(ts: qrTS)
            log("[界面] 登录二维码已生成")
            return url
        } catch {
            loginError = "\(error)"
            state = "login_required"
            log("[界面] 登录失败: \(error)")
            return nil
        }
    }

    func refreshQR() async -> String? {
        pollTask?.cancel()
        guard let info = serverInfo else { return await beginLogin() }
        let url = makeQRURL(info: info)
        state = "scanning"
        await startPoll(ts: qrTS)
        return url
    }

    private func makeQRURL(info: [String: Any]) -> String {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        qrTS = ts
        let control: String = (info["ControlUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cfg.serverBase
        let redirect = "\(control)/access/1.0/linux/json/wework/user?deviceid=\(cfg.deviceID)&time=\(ts)&zjt=1"
        let zjt = info["ZJTConfig"] as? [String: Any] ?? [:]
        let portal = (zjt["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "https://portal.cscec.com"
        let corpId = (zjt["corpId"] as? String) ?? ""
        let agentId = (zjt["agentid"] as? String) ?? ""
        let escaped = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? redirect
        let url = "\(portal)/wwopen/sso/qrConnect?appid=\(corpId)&agentid=\(agentId)&redirect_uri=\(escaped)&state=&login_type=jssdk&t=\(ts + 5)"
        qrURL = url
        return url
    }

    private func startPoll(ts: Int64) async {
        pollTask?.cancel()
        let captured = ts
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            var scanned = false
            while !Task.isCancelled {
                if !scanned {
                    if let (wecomToken, user) = await self.pollScan(ts: captured) {
                        scanned = true
                        self.state = "checking"
                        let ok = await self.finishLogin(wecomToken: wecomToken, username: user)
                        if ok { return }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// QR 页面被重定向到 SDP 服务端时调用（说明已扫码）
    func onScanned() async {
        // 轮询会自然发现 state=true；这里只是加速
        if state == "scanning" { log("[扫码] 检测到扫码跳转") }
    }

    private func pollScan(ts: Int64) async -> (String, String)? {
        do {
            let r = try await api.call(method: "POST", path: "/access/1.0/linux/json/wework/user",
                                       params: ["action": "check", "deviceid": cfg.deviceID, "time": "\(ts)"])
            guard r.errCode == "0", let d = r.data as? [String: Any] else { return nil }
            let st = (d["state"] as? Bool) ?? false
            if st, let tok = d["token"] as? String {
                return (tok, (d["username"] as? String) ?? "")
            }
        } catch {
            log("[扫码] 轮询失败: \(error)")
        }
        return nil
    }

    func finishLogin(wecomToken: String, username: String) async -> Bool {
        guard let info = serverInfo, let pub = info["pubKey"] as? String else {
            loginError = "缺少公钥"
            return false
        }
        guard let enc = RSA.encryptPKCS1(plain: Data(wecomToken.utf8), pemPublicKey: pub) else {
            loginError = "RSA 加密失败"
            return false
        }
        let encHex = enc.map { String(format: "%02x", $0) }.joined()
        let userNameB64 = Data(username.utf8).base64EncodedString()
        do {
            let r = try await api.call(method: "POST", path: "/access/1.0/linux/json/auth/index", params: [
                "type": "User", "user_name": userNameB64, "password": encHex,
                "weworkqrlogin": "1", "zjt": "1", "deviceid": cfg.deviceID,
                "autoAuth": "0", "hintOver": "0", "idp": "", "isRecord": "1",
                "remoteIp": "", "tokenId": "",
            ])
            guard r.errCode == "0", let d = r.data as? [String: Any], let tok = d["Token"] as? String else {
                loginError = "认证失败: \(r.errCode) \(r.errMsg)"
                log("[登录] \(loginError)")
                return false
            }
            token = tok
            api.token = tok
            cfg.token = tok
            try? cfg.save(path: cfgPath)
            self.username = (d["UserName"] as? String) ?? username
            log("[界面] 扫码登录成功: \(self.username)")
            state = "connected"
            sessionOK = true
            await fetchPolicy()
            startTimers()
            return true
        } catch {
            loginError = "认证异常: \(error)"
            log("[登录] \(loginError)")
            return false
        }
    }

    // MARK: - 会话 / 策略

    @discardableResult
    func checkSession() async -> Bool {
        guard token != nil else { return false }
        do {
            let r = try await api.call(method: "POST", path: "/access/1.0/linux/json/device/netStatus",
                                       params: ["deviceId": cfg.deviceID])
            var sessionStatus = ""
            if r.errCode == "0", let d = r.data as? [String: Any] {
                sessionStatus = (d["SessionStatus"] as? String) ?? ""
                if let newToken = d["Token"] as? String, !newToken.isEmpty, newToken != token {
                    token = newToken; api.token = newToken; cfg.token = newToken
                    try? cfg.save(path: cfgPath)
                    log("[会话] Token 已续期")
                }
                if let name = d["userName"] as? String, !name.isEmpty { username = name }
            }
            // 用资源接口验证 token 有效性
            let tr = try await api.call(method: "POST", path: "/access/1.0/linux/json/ztpResource/list",
                                        params: ["deviceid": cfg.deviceID, "listType": "0", "queryStr": ""])
            let tokenValid = tr.errCode != "21120055"
            let ok = (sessionStatus == "0" || sessionStatus == "8") && tokenValid
            DispatchQueue.main.async {
                self.sessionOK = ok
                if ok {
                    if self.state == "offline" || self.state == "login_required" { self.state = "connected" }
                } else if self.state == "connected" {
                    self.state = "offline"
                    self.log("[会话] 已过期，需要重新登录")
                }
            }
            return ok
        } catch {
            log("[会话] 检查失败: \(error)")
            return false
        }
    }

    func fetchPolicy() async {
        guard let token = token, !token.isEmpty else { return }
        do {
            let r = try await api.call(method: "GET", path: "/access/2.0/linux/json/resource/distributeConfig",
                                       params: ["deviceid": cfg.deviceID])
            guard r.errCode == "0", let d = r.data as? [String: Any],
                  let policyArr = d["appPolicy"] as? [[String: Any]] else {
                log("[资源] 策略表解析失败")
                return
            }
            var out: [Rule] = []
            var seen = Set<String>()
            for p in policyArr {
                let resid = (p["resID"] as? String) ?? ""
                if resid.isEmpty { continue }
                for key in ["resDomainContent", "resIpContent"] {
                    guard let content = p[key] as? String, !content.isEmpty else { continue }
                    for item in Self.parsePolicyEntries(content) {
                        let k = "\(item.host)|\(resid)|\(item.ports)"
                        if seen.insert(k).inserted {
                            out.append(Rule(pattern: item.host, resid: resid, ports: item.ports))
                        }
                    }
                }
            }
            store.replacePolicy(out)
            for (host, resid) in (cfg.learnedResources ?? [:]) {
                store.addLearned(host: host, resid: resid)
            }
            DispatchQueue.main.async { self.resourceCount = self.store.snapshot().count }
            log("[资源] 策略表 \(out.count) 条")
        } catch {
            log("[资源] 拉取失败: \(error)")
        }
    }

    struct PolicyItem { let host: String; let ports: String }

    static func parsePolicyEntries(_ s: String) -> [PolicyItem] {
        var out: [PolicyItem] = []
        for chunk in s.components(separatedBy: "##") {
            var c = chunk.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            var host = c
            var ports = ""
            if let idx = c.firstIndex(of: "/") {
                host = String(c[..<idx]).trimmingCharacters(in: .whitespaces)
                ports = String(c[c.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
            var fields = host.split(separator: " ").map(String.init)
            if let last = fields.last?.uppercased(), ["TCP", "UDP", "ALL"].contains(last) {
                fields.removeLast()
            }
            host = fields.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !host.isEmpty { out.append(PolicyItem(host: host, ports: ports)) }
        }
        return out
    }

    // MARK: - 退出登录

    func logout() async {
        pollTask?.cancel()
        token = nil
        api.token = nil
        cfg.token = ""
        try? cfg.save(path: cfgPath)
        sessionTimer?.invalidate()
        policyTimer?.invalidate()
        state = "login_required"
        sessionOK = false
        log("[退出] 已断开连接")
    }

    /// 记录自动发现的资源映射
    func learn(host: String, resid: String) {
        if cfg.learnedResources == nil { cfg.learnedResources = [:] }
        cfg.learnedResources?[host] = resid
        store.addLearned(host: host, resid: resid)
        try? cfg.save(path: cfgPath)
    }

    func cancelLogin() {
        pollTask?.cancel()
        state = token == nil ? "login_required" : "connected"
    }
}

extension Notification.Name {
    static let engineLog = Notification.Name("sdp.engine.log")
}
