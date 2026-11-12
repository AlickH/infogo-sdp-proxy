import Foundation
import Network
import Security

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum HTTPError: Error, CustomStringConvertible {
    case connect(String)
    case send(String)
    case recv(String)
    case timeout
    case badResponse(String)

    var description: String {
        switch self {
        case .connect(let s): return "连接失败: \(s)"
        case .send(let s): return "发送失败: \(s)"
        case .recv(let s): return "接收失败: \(s)"
        case .timeout: return "超时"
        case .badResponse(let s): return "响应异常: \(s)"
        }
    }
}

/// 裸 TLS HTTP/1.1 客户端：可指定连接 IP 与 SNI，绕过系统 DNS/fake-IP
enum TLSHTTP {
    static func request(
        method: String,
        host: String,
        port: UInt16,
        sni: String? = nil,
        path: String,
        headers: [String: String],
        body: Data? = nil,
        verifyTLS: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> HTTPResponse {
        let connectHost = PublicDNS.resolveIPv4(host) ?? host

        let tls = NWProtocolTLS.Options()
        let proto = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(proto, (sni ?? host))
        if !verifyTLS {
            sec_protocol_options_set_verify_block(proto, { _, _, complete in complete(true) }, DispatchQueue.global())
        }
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowFastOpen = true
        let conn = NWConnection(host: NWEndpoint.Host(connectHost),
                                port: NWEndpoint.Port(rawValue: port)!, using: params)

        try await waitReady(conn, timeout: timeout)

        var head = "\(method) \(path) HTTP/1.1\r\n"
        var hs = headers
        hs["Host"] = host
        hs["Connection"] = "close"
        hs["Accept-Encoding"] = "identity"
        if let body = body {
            hs["Content-Length"] = String(body.count)
        }
        for (k, v) in hs {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var req = Data(head.utf8)
        if let body = body { req.append(body) }

        try await send(conn, req)
        let respData = try await recvAll(conn)
        conn.cancel()

        guard let text = String(data: respData, encoding: .utf8) ?? String(data: respData, encoding: .isoLatin1),
              let range = text.range(of: "\r\n\r\n") else {
            throw HTTPError.badResponse("无响应头")
        }
        let headerPart = String(text[..<range.lowerBound])
        let bodyPart = String(text[range.upperBound...])
        var lines = headerPart.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw HTTPError.badResponse("空状态行") }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw HTTPError.badResponse("状态行异常: \(statusLine)")
        }
        lines.removeFirst()
        var hsOut: [String: String] = [:]
        for line in lines {
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                hsOut[k.lowercased()] = v
            }
        }
        var bodyData = Data(bodyPart.utf8)
        if hsOut["transfer-encoding"]?.lowercased() == "chunked" {
            bodyData = decodeChunked(bodyData)
        }
        return HTTPResponse(status: status, headers: hsOut, body: bodyData)
    }

    // MARK: - NWConnection async helpers

    private static func waitReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: HTTPError.connect(e.localizedDescription)) }
                case .cancelled: once.run { cont.resume(throwing: HTTPError.connect("已取消")) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { cont.resume(throwing: HTTPError.timeout) }
            }
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: HTTPError.send(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    private static func recvAll(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var buf = Data()
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                    if let data = data { buf.append(data) }
                    if let err = err {
                        cont.resume(throwing: HTTPError.recv(err.localizedDescription)); return
                    }
                    if isComplete { cont.resume(returning: buf); return }
                    loop()
                }
            }
            loop()
        }
    }

    private static func decodeChunked(_ data: Data) -> Data {
        var out = Data()
        var idx = 0
        let bytes = [UInt8](data)
        while idx < bytes.count {
            var lineEnd = idx
            while lineEnd + 1 < bytes.count && !(bytes[lineEnd] == 0x0D && bytes[lineEnd+1] == 0x0A) { lineEnd += 1 }
            guard lineEnd + 1 < bytes.count else { break }
            let sizeLine = String(bytes: bytes[idx..<lineEnd], encoding: .utf8) ?? ""
            let sizeStr = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeStr, radix: 16) else { break }
            let start = lineEnd + 2
            if size == 0 { break }
            if start + size <= bytes.count {
                out.append(contentsOf: bytes[start..<(start+size)])
            }
            idx = start + size + 2
        }
        return out
    }
}
