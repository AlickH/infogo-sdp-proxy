import Foundation

struct APIResp {
    var errCode: String
    var errMsg: String
    var data: Any?
    var raw: Data
}

/// SDP 服务端 API 客户端（自定义 DNS + SNI + Session-Num）
final class SDPApiClient {
    let base: String
    private let host: String
    private let port: UInt16
    private let scheme: String
    var token: String?

    init(base: String, token: String? = nil) {
        self.base = base
        self.token = token
        let url = URL(string: base)!
        self.host = url.host ?? ""
        self.scheme = url.scheme ?? "https"
        self.port = UInt16(url.port ?? (scheme == "https" ? 443 : 80))
    }

    func call(method: String, path: String, params: [String: String]) async throws -> APIResp {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        var baseURL = "\(base)\(path)?local_lguage_set=zh&cache=\(ts)"
        let keys = params.keys.sorted()
        var sessionURL = baseURL
        for k in keys { sessionURL += "&\(k)=\(params[k]!)" }
        let sessionStr = String(sessionURL.dropFirst(base.count))
        let sessionNum = SessionNum.compute(sessionStr)

        var body: Data?
        if method == "GET" {
            for k in keys {
                let esc = params[k]!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                baseURL += "&\(k)=\(esc)"
            }
        } else if !keys.isEmpty {
            // 严格表单编码：+ / = 等必须转义，否则 base64 里的 + 会被服务端当成空格
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            func esc(_ v: String) -> String {
                v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            }
            body = Data(keys.map { "\(esc($0))=\(esc(params[$0]!))" }.joined(separator: "&").utf8)
        }

        guard let url = URL(string: baseURL) else { throw HTTPError.badResponse("URL 无效") }
        var headers: [String: String] = [
            "Session-Num": sessionNum,
            "Referer": base + "/",
            "User-Agent": "Mozilla/5.0",
        ]
        if method != "GET" { headers["Content-Type"] = "application/x-www-form-urlencoded" }
        if let token = token, !token.isEmpty { headers["Web-Token"] = token }

        let resp = try await TLSHTTP.request(
            method: method,
            host: host,
            port: port,
            path: url.path + (url.query.map { "?\($0)" } ?? ""),
            headers: headers,
            body: body,
            verifyTLS: true,
            timeout: 20
        )
        var data = resp.body
        if let idx = data.firstIndex(of: UInt8(ascii: "{")) {
            data = data[idx...]
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let code: String
        if let s = obj["errcode"] as? String { code = s }
        else if let n = obj["errcode"] as? NSNumber { code = n.stringValue }
        else { code = "" }
        return APIResp(errCode: code,
                       errMsg: (obj["errmsg"] as? String) ?? "",
                       data: obj["data"],
                       raw: resp.body)
    }

    /// 获取服务端基础信息（登录页构造用）
    func serverInfo() async throws -> [String: Any] {
        let r = try await call(method: "GET",
                               path: "/access/1.0/linux/json/server/info",
                               params: ["basIP": "", "firsturl": "", "version": "6039.3746"])
        guard r.errCode == "0" else {
            throw HTTPError.badResponse("server/info 失败: \(r.errCode) \(r.errMsg)")
        }
        return (r.data as? [String: Any]) ?? [:]
    }
}
