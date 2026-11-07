import Foundation

@main
struct TestMain {
    static func main() async {
        do {
            let cfg = try SDPConfig.load()
            let api = SDPApiClient(base: cfg.serverBase, token: cfg.token)
            print("服务端: \(cfg.serverBase)")

            // 1) 策略表
            let pol = try await api.call(method: "GET", path: "/access/2.0/linux/json/resource/distributeConfig",
                                         params: ["deviceid": cfg.deviceID])
            if let data = pol.data as? [String: Any], let policy = data["appPolicy"] as? [[String: Any]] {
                print("策略表: \(policy.count) 条")
                var found: [String: String] = [:]
                for p in policy {
                    if let d = p["resDomainContent"] as? String, !d.isEmpty, let rid = p["resID"] as? String {
                        let host = d.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                        if !host.isEmpty { found[host] = rid }
                    }
                }
                for k in ["bip.cscec5b.com.cn", "ebpm.cscec5b.com.cn", "oa.cscec5b.com.cn"] {
                    print("  \(k) -> \(found[k] ?? "无")")
                }
            } else {
                print("策略表解析失败: errcode=\(pol.errCode) msg=\(pol.errMsg)")
            }

            // 2) 资源列表
            let list = try await api.call(method: "POST", path: "/access/1.0/linux/json/ztpResource/list",
                                          params: ["deviceid": cfg.deviceID, "listType": "0", "queryStr": ""])
            print("资源列表 errcode=\(list.errCode) msg=\(list.errMsg)")

            // 3) 网关隧道（bip:443 resid=135）
            let gw = cfg.gateway.split(separator: ",").first.map(String.init) ?? ""
            print("连接网关 \(gw) → bip.cscec5b.com.cn:443 resid=135 ...")
            let t0 = Date()
            let tunnel = try await Gateway.dial(gateway: gw, serverName: cfg.serverName,
                                                token: cfg.token ?? "", host: "bip.cscec5b.com.cn",
                                                port: 443, resid: "135")
            print("隧道建立成功，耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            tunnel.cancel()

            // 4) RSA 公钥测试
            let info = try await api.serverInfo()
            print("server/info keys: \(Array(info.keys).sorted().prefix(8))")
            if let pub = info["pubKey"] as? String {
                if let enc = RSA.encryptPKCS1(plain: Data("hello".utf8), pemPublicKey: pub) {
                    print("RSA 加密成功: \(enc.count) 字节")
                } else {
                    print("RSA 加密失败")
                }
            } else {
                print("server/info 中没有 pubKey")
            }
            if let zjt = info["ZJTConfig"] as? [String: Any] {
                print("ZJTConfig: url=\(zjt["URL"] ?? "-") corpId=\(zjt["CorpID"] ?? "-") agentid=\(zjt["AgentID"] ?? "-")")
            }
        } catch {
            print("失败: \(error)")
        }
    }
}
