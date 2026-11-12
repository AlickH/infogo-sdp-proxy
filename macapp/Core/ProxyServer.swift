import Foundation
import Network

/// 本地代理服务：SOCKS5(11095) / HTTP(11096) / 规则服务(28181)
/// `@unchecked Sendable`：NWListener 的 @Sendable 回调需要把 self 带进 Task；
/// 本类的可变状态（listener/running）只在 start/stop 中于主流程写入，符合「外部串行化」前提。
final class ProxyServer: @unchecked Sendable {
    private let engine: Engine
    private let store: RuleStore
    private var socsListener: NWListener?
    private var httpListener: NWListener?
    private var ruleListener: NWListener?
    private let queue = DispatchQueue(label: "sdp.proxy", attributes: .concurrent)
    private(set) var running = false

    init(engine: Engine) {
        self.engine = engine
        self.store = engine.store
    }

    func start() {
        let (_, socksPort) = SDPConfig.splitHostPort(engine.cfg.listen)
        let (_, httpPort) = SDPConfig.splitHostPort(engine.cfg.httpListen)
        let (_, rulePort) = SDPConfig.splitHostPort(engine.cfg.uiListen)
        do {
            socsListener = try listen(port: socksPort) { [weak self] conn in
                Task { await self?.handleSOCKS(conn) }
            }
            httpListener = try listen(port: httpPort) { [weak self] conn in
                Task { await self?.handleHTTP(conn) }
            }
            ruleListener = try listen(port: rulePort) { [weak self] conn in
                Task { await self?.handleRule(conn) }
            }
            running = true
            engine.log("[代理] SOCKS5 :\(socksPort) / HTTP :\(httpPort) / 规则 :\(rulePort)")
        } catch {
            engine.log("[代理] 启动失败: \(error)")
        }
    }

    func stop() {
        socsListener?.cancel(); httpListener?.cancel(); ruleListener?.cancel()
        running = false
    }

    private func listen(port: UInt16, handler: @escaping (NWConnection) -> Void) throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Swift 6：newConnectionHandler 是 @Sendable，handler 本身非 Sendable；此处仅转交调用，显式放行
        nonisolated(unsafe) let deliver = handler
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            deliver(conn)
        }
        l.start(queue: .global())
        return l
    }

    // MARK: - 路由

    private func openUpstream(host: String, port: UInt16) async throws -> ByteStream {
        let directDomains = engine.cfg.directDomains ?? []
        if store.isDirectDomain(host, directDomains: directDomains) {
            engine.log("[直连] \(host):\(port) (公网入口)")
            return try await dialDirect(host: host, port: port)
        }
        let resid = store.resid(host: host, port: port)
        if let token = engine.token, !token.isEmpty, !resid.isEmpty {
            let gw = engine.cfg.gateway.split(separator: ",").first.map(String.init) ?? ""
            do {
                let t = try await Gateway.dial(gateway: gw, serverName: engine.cfg.serverName,
                                               token: token, host: host, port: port, resid: resid)
                engine.log("[隧道] \(host):\(port) (resid=\(resid))")
                return t
            } catch {
                engine.log("[隧道失败] \(host):\(port) resid=\(resid): \(error)")
                if !store.hostKnown(host), let learned = await discoverResid(host: host, port: port) {
                    if let t = try? await Gateway.dial(gateway: gw, serverName: engine.cfg.serverName,
                                                       token: token, host: host, port: port, resid: learned) {
                        engine.log("[资源] \(host) 发现 resid=\(learned)（已缓存）")
                        engine.learn(host: host, resid: learned)
                        return t
                    }
                }
            }
        }
        engine.log("[直连] \(host):\(port)")
        return try await dialDirect(host: host, port: port)
    }

    /// 未知域名自动发现资源 ID（候选来自策略表）
    private func discoverResid(host: String, port: UInt16) async -> String? {
        var seen = Set<String>()
        var candidates: [String] = []
        for r in store.snapshot() where seen.insert(r.resid).inserted {
            candidates.append(r.resid)
        }
        if candidates.count < 10 { candidates = (1...200).map(String.init) }
        guard let token = engine.token, !token.isEmpty else { return nil }
        let gw = engine.cfg.gateway.split(separator: ",").first.map(String.init) ?? ""
        let serverName = engine.cfg.serverName
        return await withTaskGroup(of: String?.self) { group in
            var index = 0
            let limit = 12
            while index < min(limit, candidates.count) {
                let rid = candidates[index]; index += 1
                group.addTask {
                    if let t = try? await Gateway.dial(gateway: gw, serverName: serverName,
                                                       token: token, host: host, port: port, resid: rid) {
                        t.cancel(); return rid
                    }
                    return nil
                }
            }
            var found: String?
            while let r = await group.next() {
                if let r = r, found == nil {
                    found = r
                    group.cancelAll()
                }
                if index < candidates.count, found == nil {
                    let rid = candidates[index]; index += 1
                    group.addTask {
                        if let t = try? await Gateway.dial(gateway: gw, serverName: serverName,
                                                           token: token, host: host, port: port, resid: rid) {
                            t.cancel(); return rid
                        }
                        return nil
                    }
                }
            }
            return found
        }
    }

    // MARK: - SOCKS5

    private func handleSOCKS(_ conn: NWConnection) async {
        let stream = SocketStream(conn: conn)
        do {
            let hdr = try await readExactly(stream, 2)
            guard hdr[0] == 0x05 else { conn.cancel(); return }
            _ = try await readExactly(stream, Int(hdr[1]))
            try await stream.send(Data([0x05, 0x00]))
            let req = try await readExactly(stream, 4)
            guard req[0] == 0x05, req[1] == 0x01 else { conn.cancel(); return }
            var host = ""
            var port: UInt16 = 0
            switch req[3] {
            case 0x01:
                let ip = try await readExactly(stream, 4)
                host = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
            case 0x03:
                let l = try await readExactly(stream, 1)
                let d = try await readExactly(stream, Int(l[0]))
                host = String(data: d, encoding: .utf8) ?? ""
            case 0x04:
                let ip6 = try await readExactly(stream, 16)
                host = ip6.map { String(format: "%02x", $0) }.joined() // IPv6 直连场景很少
            default:
                conn.cancel(); return
            }
            let p = try await readExactly(stream, 2)
            port = UInt16(p[0]) << 8 | UInt16(p[1])

            let up = try await openUpstream(host: host, port: port)
            try await stream.send(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            await relay(stream, up)
        } catch {
            engine.log("[SOCKS] 处理失败: \(error)")
            try? await stream.send(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
            conn.cancel()
        }
    }

    // MARK: - HTTP 代理

    private func handleHTTP(_ conn: NWConnection) async {
        let stream = SocketStream(conn: conn)
        var method = ""
        do {
            let head = try await readHTTPHeaders(stream)
            guard let text = String(data: head, encoding: .utf8) else { conn.cancel(); return }
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first else { conn.cancel(); return }
            let parts = first.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            method = String(parts[0])
            let target = String(parts[1])

            if method == "CONNECT" {
                let hp = target.split(separator: ":")
                let host = String(hp[0])
                let port = UInt16(hp.count > 1 ? (UInt16(hp[1]) ?? 443) : 443)
                let up = try await openUpstream(host: host, port: port)
                try await stream.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                await relay(stream, up)
                return
            }

            guard let url = URL(string: target), let host = url.host else {
                try? await stream.send(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
                conn.cancel()
                return
            }
            let port = UInt16(url.port ?? 80)
            let up = try await openUpstream(host: host, port: port)
            var originPath = url.path.isEmpty ? "/" : url.path
            if let q = url.query { originPath += "?" + q }
            var out = "\(method) \(originPath) HTTP/1.1\r\n"
            var bodyData = Data()
            for line in lines.dropFirst() where !line.isEmpty {
                let lower = line.lowercased()
                if lower.hasPrefix("proxy-connection:") || lower.hasPrefix("connection:") { continue }
                out += line + "\r\n"
            }
            // 读取请求体（Content-Length）
            if let clLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
               let cl = Int(clLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0"),
               cl > 0 {
                bodyData = try await readExactly(stream, cl)
            }
            out += "\r\n"
            var reqData = Data(out.utf8)
            reqData.append(bodyData)
            try await up.send(reqData)
            await relay(stream, up)
        } catch {
            engine.log("[HTTP] 处理失败: \(error)")
            // 与 Go 版一致：CONNECT 与 absolute-form 失败都回 502
            try? await stream.send(Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            conn.cancel()
        }
    }

    // MARK: - 规则服务

    private func handleRule(_ conn: NWConnection) async {
        let stream = SocketStream(conn: conn)
        do {
            let head = try await readHTTPHeaders(stream)
            guard let text = String(data: head, encoding: .utf8),
                  let firstLine = text.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            let parts = firstLine.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : "/"
            let body: String
            switch path {
            case "/surge.list":
                body = RuleText.surge(store: store, cfg: engine.cfg)
            case "/clash.list":
                body = RuleText.clash(store: store, cfg: engine.cfg)
            default:
                body = "SDP Proxy\n"
            }
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            try await stream.send(Data(resp.utf8))
            conn.cancel()
        } catch {
            conn.cancel()
        }
    }
}
