import Foundation

struct ResourceEntry: Codable {
    var domain: String
    var resid: String
    var ports: String?
}

struct SDPConfig: Codable {
    var gateway: String
    var serverName: String
    var serverBase: String
    var deviceID: String
    var token: String?
    var tokenTimestamp: Int64?
    var listen: String
    var httpListen: String
    var uiListen: String
    var resources: [ResourceEntry]?
    var learnedResources: [String: String]?
    var directDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case gateway
        case serverName = "server_name"
        case serverBase = "server_base"
        case deviceID = "device_id"
        case token
        case tokenTimestamp = "token_timestamp"
        case listen
        case httpListen = "http_listen"
        case uiListen = "ui_listen"
        case resources
        case learnedResources = "learned_resources"
        case directDomains = "direct_domains"
    }

    static var defaultPath: String {
        NSHomeDirectory() + "/.sdp-proxy/config.json"
    }

    static func load(path: String = SDPConfig.defaultPath) throws -> SDPConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SDPConfig.self, from: data)
    }

    func save(path: String = SDPConfig.defaultPath) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 解析 listen 形式 "127.0.0.1:11095"
    static func splitHostPort(_ s: String) -> (String, UInt16) {
        let parts = s.split(separator: ":")
        if parts.count == 2, let p = UInt16(parts[1]) {
            return (String(parts[0]), p)
        }
        return ("127.0.0.1", 0)
    }
}
