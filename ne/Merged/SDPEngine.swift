import Foundation
import NetworkExtension
import Network
import Darwin

/// 合并模式下的 SDP 透明代理引擎。
///
/// 由合并前 SDPNE 的 `Provider` 整体搬来（该文件已随合并删除），去掉 `NEPacketTunnelProvider` 继承、
/// `setTunnelNetworkSettings` 和 `packetFlow` 持有：
/// 网络设置与 flow 由 `PacketDispatcher` 统一管，这里只负责
/// hev（lwIP + SOCKS5）这条管道本身。
///
/// 数据面：
///   deliver(packet) → 加 4 字节 AF 头 → bridgeFD → hev
///   hev → bridgeFD → 去掉 AF 头 → 修正校验和 → onOutbound 回调
final class SDPEngine: TunnelEngine, @unchecked Sendable {
    let name = "sdp"

    private(set) var routes: [String] = []
    private(set) var excludeRoutes: [String] = []
    private(set) var addresses: [String] = ["198.19.0.1/24"]
    let dnsServers: [String] = []
    let dnsMatchDomain = ""
    private(set) var mtu = 1500

    private var token = ""
    private var gateways: [String] = []
    private var serverName = ""
    private var directDomains: [String] = []

    /// 网关就是我们自己的外联目标，必须排除出隧道
    var outboundTargets: [String] {
        gateways.map { $0 }
    }
    private var store = RuleStore()

    private var hevFD: Int32 = -1
    private var bridgeFD: Int32 = -1
    private var socksListener: NWListener?
    private var bridgeSource: DispatchSourceRead?
    private var running = false
    private var outbound: ((Data) -> Void)?

    private func log(_ s: String) {
        Diag.log("sdp", s)
    }

    /// 配置值可能是 String / NSNumber（JSON 策略表里的 resid、ports 是数字），
    /// 统一转成字符串，避免 `as? [[String: String]]` 这类整体转换静默失败。
    private static func text(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: - 生命周期

    /// 只算路由 / 排除网段 / MTU，供 dispatcher 在建设置前调用。
    func prepare(config: [String: Any]) {
        routes = (config["routes"] as? [String]) ?? []
        excludeRoutes = (config["excludeRoutes"] as? [String]) ?? []
        if let m = config["mtu"] as? Int, m >= 576 { mtu = m }
    }

    func start(config: [String: Any], completion: @escaping (Error?) -> Void) {
        prepare(config: config)
        token = (config["token"] as? String) ?? ""
        serverName = (config["serverName"] as? String) ?? "sdp.cscec5b.com.cn"
        gateways = (config["gateways"] as? [String]) ?? []
        directDomains = (config["directDomains"] as? [String]) ?? []

        // rules 里的 resid / ports 可能来自 JSON 策略表，是数字而不是字符串；
        // 用 [[String: String]] 整体转换时只要有一个值不是 String 就会整段返回 nil，
        // 规则表会静默变空（表现：每个目标都 "no route ... resid="）。所以逐字段取值。
        if let arr = config["rules"] as? [[String: Any]] {
            let parsed = arr.compactMap { d -> Rule? in
                let p = Self.text(d["pattern"])
                let resid = Self.text(d["resid"])
                guard !p.isEmpty, !resid.isEmpty else { return nil }
                return Rule(pattern: p, resid: resid, ports: Self.text(d["ports"]))
            }
            store.replacePolicy(parsed)
            log("rules=\(parsed.count)")
        }
        log("start gateways=\(gateways) routes=\(routes.count) exclude=\(excludeRoutes.count) mtu=\(mtu)")

        startSocks()
        startHevBridge()
        completion(nil)
    }

    func stop() {
        running = false
        socksListener?.cancel(); socksListener = nil
        bridgeSource?.cancel(); bridgeSource = nil
        if bridgeFD >= 0 { close(bridgeFD); bridgeFD = -1 }
        if hevFD >= 0 {
            hev_socks5_tunnel_quit()
            close(hevFD); hevFD = -1
        }
        log("stopped")
    }

    func onOutbound(_ handler: @escaping (Data) -> Void) { outbound = handler }

    func handleMessage(_ message: Data, completion: @escaping (Data?) -> Void) {
        let cmd = String(data: message, encoding: .utf8) ?? ""
        completion(cmd == "ping" ? Data("pong".utf8) : nil)
    }

    // MARK: - hev 桥接

    private func startHevBridge() {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            log("socketpair failed"); return
        }
        hevFD = fds[0]
        bridgeFD = fds[1]
        let hevFDValue = fds[0]
        var sz: Int32 = 4 * 1024 * 1024
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
        }

        let yaml = """
        tunnel:
          name: utun0
          mtu: \(mtu)
          ipv4: 198.19.0.1
          ipv6: 'fc00::1'
          icmp: 'off'
        socks5:
          port: 11097
          address: 127.0.0.1
          udp: 'udp'
        misc:
          log-level: info
          tcp-buffer-size: 8192
        """
        let yamlBytes = Array(yaml.utf8)
        running = true
        log("hev starting fd=\(fds[0]) bridge=\(fds[1])")
        let thread = Thread { [weak self] in
            let rc = yamlBytes.withUnsafeBufferPointer { buf in
                hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(buf.count), hevFDValue)
            }
            self?.log("hev exited rc=\(rc)")
        }
        thread.name = "hev"
        thread.start()

        // hev → OS：非阻塞 drain，避免一次空事件后永久阻塞
        let source = DispatchSource.makeReadSource(fileDescriptor: bridgeFD, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }
            while true {
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = recv(self.bridgeFD, &buf, buf.count, MSG_DONTWAIT)
                guard n > 4 else { break }
                let pkt = Self.fixChecksums(Data(buf[4..<n]))
                self.outbound?(pkt)
            }
        }
        source.resume()
        bridgeSource = source
    }

    /// OS → hev：裸 IP 包前加 4 字节 AF 头后写入 socketpair
    func deliver(_ packet: Data) {
        guard running, bridgeFD >= 0 else { return }
        let version = (packet.first ?? 0) >> 4
        let af: UInt32 = version == 6 ? UInt32(AF_INET6) : UInt32(AF_INET)
        var out = Data()
        var type = af.bigEndian
        withUnsafeBytes(of: &type) { out.append(contentsOf: $0) }
        out.append(packet)
        let sent = out.withUnsafeBytes { buf in
            send(bridgeFD, buf.baseAddress, buf.count, MSG_DONTWAIT)
        }
        if sent < 0 { log("send bridge error \(errno)") }
    }

    // MARK: - 本地 SOCKS（hev 的出口）

    private func startSocks() {
        let params = NWParameters.tcp
        guard let port = NWEndpoint.Port(rawValue: 11097) else { return }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else {
            log("socks listener create failed"); return
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.log("socks listener state=\(state)")
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            Task { await self?.handleSocks(conn) }
        }
        listener.start(queue: .global())
        socksListener = listener
        log("socks listener on 11097")
    }

    private func handleSocks(_ conn: NWConnection) async {
        let client = SocketStream(conn: conn)
        do {
            let greeting = try await readExactly(client, 2)
            _ = try await readExactly(client, Int(greeting[1]))
            try await client.send(Data([0x05, 0x00]))

            let req = try await readExactly(client, 4)
            var host = ""
            switch req[3] {
            case 0x01:
                let ip = try await readExactly(client, 4)
                host = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
            case 0x03:
                let l = try await readExactly(client, 1)
                host = String(data: try await readExactly(client, Int(l[0])), encoding: .utf8) ?? ""
            case 0x04:
                host = "IPv6"
                _ = try await readExactly(client, 16)
            default:
                conn.cancel(); return
            }
            let p = try await readExactly(client, 2)
            let port = UInt16(p[0]) << 8 | UInt16(p[1])

            // 先回 SOCKS 成功，让 hev 发送 TLS ClientHello
            try await client.send(Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))

            // 嗅探 SNI：直接读第一段数据（ClientHello），不做超时 race
            var peek = Data()
            if let chunk = try await client.receive() { peek.append(chunk) }
            var sni = Self.parseSNI(peek) ?? Self.parseHTTPHost(peek)
            if sni == nil, let more = try await client.receive() {
                peek.append(more)
                sni = Self.parseSNI(peek) ?? Self.parseHTTPHost(peek)
            }
            let target = sni ?? host
            log("socks \(host):\(port) sni=\(sni ?? "-")")

            let resid = store.resid(host: target, port: port)
            let liveToken = SharedToken.read() ?? token
            var upstream: ByteStream?
            if !resid.isEmpty, !liveToken.isEmpty, let gw = gateways.first {
                do {
                    upstream = try await Gateway.dial(gateway: gw, serverName: serverName,
                                                      token: liveToken, host: target,
                                                      port: port, resid: resid)
                    log("tunnel ok \(target):\(port) resid=\(resid)")
                } catch {
                    log("gateway fail \(target):\(port) resid=\(resid) err=\(error)")
                }
            }
            guard let up = upstream else {
                log("no route for \(target):\(port) resid=\(resid)")
                conn.cancel(); return
            }

            nonisolated(unsafe) let upStream = up
            nonisolated(unsafe) let clientStream = client
            nonisolated(unsafe) let logFn = log
            let back = Task { await Self.pipe(upStream, clientStream, "t->c", logFn) }
            if !peek.isEmpty { try await up.send(peek) }
            await Self.pipe(client, up, "c->t", log)
            _ = await back.value
            try? await Task.sleep(nanoseconds: 300_000_000)
            conn.cancel()
            log("relay end")
        } catch {
            log("socks error \(error)")
            conn.cancel()
        }
    }

    // MARK: - 工具

    /// 注入前修正 IPv4/TCP/UDP 校验和，避免 lwIP offload 导致内核丢包
    static func fixChecksums(_ data: Data) -> Data {
        var p = [UInt8](data)
        guard p.count >= 20, (p[0] >> 4) == 4 else { return data }
        let ihl = Int(p[0] & 0x0F) * 4
        guard p.count >= ihl else { return data }

        func cs(_ bytes: ArraySlice<UInt8>) -> UInt16 {
            var sum: UInt32 = 0
            var i = bytes.startIndex
            while i + 1 < bytes.endIndex {
                sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i+1])
                i += 2
            }
            if i < bytes.endIndex { sum += UInt32(bytes[i]) << 8 }
            while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
            return UInt16(~sum & 0xFFFF)
        }

        p[10] = 0; p[11] = 0
        let ipc = cs(p[0..<ihl])
        p[10] = UInt8(ipc >> 8); p[11] = UInt8(ipc & 0xFF)

        let proto = p[9]
        let totalLen = min(p.count, Int(p[2]) << 8 | Int(p[3]))
        if (proto == 6 || proto == 17), totalLen >= ihl + 8 {
            let off = proto == 6 ? 16 : 6
            p[ihl + off] = 0; p[ihl + off + 1] = 0
            var pseudo = [UInt8]()
            pseudo.append(contentsOf: p[12..<16])
            pseudo.append(contentsOf: p[16..<20])
            pseudo.append(0); pseudo.append(proto)
            let segLen = UInt16(totalLen - ihl)
            pseudo.append(UInt8(segLen >> 8)); pseudo.append(UInt8(segLen & 0xFF))
            pseudo.append(contentsOf: p[ihl..<totalLen])
            var c = cs(pseudo[...])
            if c == 0 { c = 0xFFFF }
            p[ihl + off] = UInt8(c >> 8); p[ihl + off + 1] = UInt8(c & 0xFF)
        }
        return Data(p)
    }

    static func pipe(_ from: ByteStream, _ to: ByteStream, _ label: String,
                     _ log: @escaping (String) -> Void) async {
        do {
            while true {
                guard let d = try await from.receive() else { break }
                log("\(label) \(d.count) bytes")
                try await to.send(d)
            }
        } catch { log("\(label) error \(error)") }
        await to.closeWrite()
    }

    /// 从 HTTP 请求里取目标主机名。
    ///
    /// `Host` 头通常带端口（`Host: 172.30.193.1:30080`），必须剥掉——否则
    /// 调用方再拼一次端口会得到 `172.30.193.1:30080:30080`，规则表按这个
    /// 畸形主机名永远匹配不到（表现为 `no route ... resid=`，连接被丢弃）。
    static func parseHTTPHost(_ data: Data) -> String? {
        guard data.count > 16 else { return nil }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        for line in text.split(separator: "\r\n") {
            guard line.lowercased().hasPrefix("host:") else { continue }
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            // IPv6 字面量形如 [::1]:8080，端口分隔在 "]" 之后
            if value.hasPrefix("[") {
                if let close = value.firstIndex(of: "]") {
                    return String(value[value.index(after: value.startIndex)..<close])
                }
                return value
            }
            if let colon = value.lastIndex(of: ":") {
                return String(value[..<colon])
            }
            return value
        }
        return nil
    }

    static func parseSNI(_ data: Data) -> String? {
        let d = [UInt8](data)
        guard d.count > 5, d[0] == 0x16, d[1] == 0x03, d[5] == 0x01 else { return nil }
        var i = 9
        guard i + 35 <= d.count else { return nil }
        i += 34
        if i >= d.count { return nil }
        let sid = Int(d[i]); i += 1 + sid
        guard i + 2 <= d.count else { return nil }
        let cs = Int(d[i]) << 8 | Int(d[i+1]); i += 2 + cs
        guard i + 1 <= d.count else { return nil }
        let comp = Int(d[i]); i += 1 + comp
        guard i + 2 <= d.count else { return nil }
        let extLen = Int(d[i]) << 8 | Int(d[i+1]); i += 2
        let end = min(i + extLen, d.count)
        while i + 4 <= end {
            let type = Int(d[i]) << 8 | Int(d[i+1])
            let len = Int(d[i+2]) << 8 | Int(d[i+3])
            i += 4
            if type == 0 && i + len <= d.count {
                var j = i
                guard j + 2 <= i + len else { return nil }
                j += 2
                guard j + 3 <= i + len else { return nil }
                j += 1
                let nameLen = Int(d[j]) << 8 | Int(d[j+1]); j += 2
                guard j + nameLen <= i + len else { return nil }
                return String(bytes: d[j..<(j+nameLen)], encoding: .utf8)
            }
            i += len
        }
        return nil
    }
}
