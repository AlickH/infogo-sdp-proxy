import Foundation
import Network
import Security

enum GatewayError: Error, CustomStringConvertible {
    case connect(String)
    case auth(String)
    case rejected(String)
    case closed

    var description: String {
        switch self {
        case .connect(let s): return "连接失败: \(s)"
        case .auth(let s): return "认证失败: \(s)"
        case .rejected(let s): return "CONNECT 被拒绝: \(s)"
        case .closed: return "连接已关闭"
        }
    }
}

/// 已建立的网关隧道（原始 TCP 流）
final class Tunnel {
    let conn: NWConnection
    private let queue = DispatchQueue(label: "sdp.tunnel")
    private var pending: Data = Data()
    private var closed = false

    init(conn: NWConnection) {
        self.conn = conn
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: GatewayError.connect(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    /// 读取最多 max 字节；返回 nil 表示对端关闭
    func receive(max: Int = 65536) async throws -> Data? {
        if !pending.isEmpty {
            let n = min(pending.count, max)
            let out = pending.prefix(n)
            pending.removeFirst(n)
            return out
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            var done = false
            func finish(_ result: Result<Data?, Error>) {
                guard !done else { return }
                done = true
                cont.resume(with: result)
            }
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, err in
                if let err = err { finish(.failure(GatewayError.connect(err.localizedDescription))); return }
                if let data = data, !data.isEmpty { finish(.success(data)); return }
                if isComplete { finish(.success(nil)); return }
                finish(.success(nil))
            }
        }
    }

    func receiveExactly(_ n: Int) async throws -> Data {
        var out = Data()
        while out.count < n {
            if !pending.isEmpty {
                let need = n - out.count
                let take = min(pending.count, need)
                out.append(pending.prefix(take))
                pending.removeFirst(take)
                continue
            }
            guard let chunk = try await receiveRaw() else { throw GatewayError.closed }
            pending.append(chunk)
        }
        return out
    }

    private func receiveRaw() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err = err { cont.resume(throwing: GatewayError.connect(err.localizedDescription)); return }
                if let data = data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(returning: isComplete ? nil : nil)
            }
        }
    }

    func cancel() { conn.cancel() }
}

enum Gateway {
    /// 建立网关隧道（协议：TLS → SOCKS5 协商 → auth 帧 → CONNECT 帧）
    static func dial(
        gateway: String,
        serverName: String,
        token: String,
        host: String,
        port: UInt16,
        resid: String,
        verifyTLS: Bool = false,
        timeout: TimeInterval = 12
    ) async throws -> Tunnel {
        let parts = gateway.split(separator: ":")
        guard parts.count == 2, let gwPort = UInt16(parts[1]) else {
            throw GatewayError.connect("网关地址无效: \(gateway)")
        }
        let gwHost = String(parts[0])
        let ip = PublicDNS.resolveIPv4(gwHost) ?? gwHost

        let tls = NWProtocolTLS.Options()
        let proto = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(proto, serverName)
        if !verifyTLS {
            sec_protocol_options_set_verify_block(proto, { _, _, complete in complete(true) }, DispatchQueue.global())
        }
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: gwPort)!, using: params)
        try await waitReady(conn, timeout: timeout)

        let tunnel = Tunnel(conn: conn)

        // 1) SOCKS5 协商
        try await tunnel.send(Data([0x05, 0x01, 0x80]))
        let hello = try await tunnel.receiveExactly(2)
        guard hello[0] == 0x05 else { throw GatewayError.auth("协商响应异常: \(hello.hex)") }

        // 2) auth: 0x80 | len(token) | token | len(resid) | resid
        let tokenB = Array(token.utf8)
        let residB = Array(resid.utf8)
        var auth = Data([0x80, UInt8(tokenB.count)])
        auth.append(contentsOf: tokenB)
        auth.append(UInt8(residB.count))
        auth.append(contentsOf: residB)
        try await tunnel.send(auth)
        let ar = try await tunnel.receiveExactly(2)
        guard ar[0] == 0x80 else { throw GatewayError.auth("认证响应异常: \(ar.hex)") }
        if ar[1] == 0x21 { throw GatewayError.auth("token 无效") }

        // 3) CONNECT
        let infoJSON: [String: Any] = [
            "version": 1,
            "data": [
                "client_ip": localIPAddress() ?? "0.0.0.0",
                "process_name": "isaproxy",
                "os": "linux",
            ],
        ]
        let infoData = try JSONSerialization.data(withJSONObject: infoJSON)
        let info = infoData.base64EncodedString()
        let infoB = Array(info.utf8)
        let hostB = Array(host.utf8)

        var req = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostB.count)])
        req.append(contentsOf: hostB)
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        req.append(0x00)
        req.append(UInt8(infoB.count))
        req.append(contentsOf: infoB)
        try await tunnel.send(req)

        let rep = try await tunnel.receiveExactly(4)
        if rep[1] != 0x00 {
            tunnel.cancel()
            throw GatewayError.rejected(rep.hex)
        }
        switch rep[3] {
        case 0x01:
            _ = try await tunnel.receiveExactly(4)
        case 0x03:
            let l = try await tunnel.receiveExactly(1)
            _ = try await tunnel.receiveExactly(Int(l[0]))
        case 0x04:
            _ = try await tunnel.receiveExactly(16)
        default:
            break
        }
        _ = try await tunnel.receiveExactly(2)
        return tunnel
    }

    private static func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            let lock = NSLock()
            func finish(_ r: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                cont.resume(with: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(GatewayError.connect(e.localizedDescription)))
                case .cancelled: finish(.failure(GatewayError.connect("已取消")))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(GatewayError.connect("超时")))
            }
        }
    }

    static func localIPAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = first
        while true {
            let ifa = ptr.pointee
            if ifa.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addr = String(cString: hostname)
                        break
                    }
                }
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }
        return addr
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
