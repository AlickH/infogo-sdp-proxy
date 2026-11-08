import Foundation
import NetworkExtension
import Network
import Darwin

final class Provider: NEPacketTunnelProvider {
    private var token = ""
    private var gateways: [String] = []
    private var serverName = ""
    private var rules: [Rule] = []
    private var directDomains: [String] = []
    private var store = RuleStore()

    private var hevFD: Int32 = -1
    private var bridgeFD: Int32 = -1
    private var socksListener: NWListener?
    private var running = false

    private func log(_ s: String) {
        NSLog("[TUN] %@", s)
        let line = "\(Date()) \(s)\n"
        let path = "/tmp/sdpne.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 启动

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        let cfg = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        token = (cfg["token"] as? String) ?? ""
        serverName = (cfg["serverName"] as? String) ?? "sdp.cscec5b.com.cn"
        gateways = (cfg["gateways"] as? [String]) ?? []
        directDomains = (cfg["directDomains"] as? [String]) ?? []
        if let arr = cfg["rules"] as? [[String: String]] {
            rules = arr.compactMap { d in
                guard let p = d["pattern"], let r = d["resid"] else { return nil }
                return Rule(pattern: p, resid: r, ports: d["ports"] ?? "")
            }
        }
        store.replacePolicy(rules)
        log("startTunnel token=\(token.isEmpty ? "nil" : "ok") gateways=\(gateways) rules=\(rules.count)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: 1500)
        let ipv4 = NEIPv4Settings(addresses: ["198.19.0.1"], subnetMasks: ["255.255.255.0"])
        let routeCIDRs = (cfg["routes"] as? [String]) ?? []
        ipv4.includedRoutes = routeCIDRs.compactMap { Self.route($0) }
        let excludes = (cfg["excludeRoutes"] as? [String]) ?? []
        ipv4.excludedRoutes = excludes.compactMap { Self.route($0) }
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            self.log("setTunnelNetworkSettings error=\(String(describing: error))")
            if let error = error { completionHandler(error); return }
            self.startSocks()
            self.startHevBridge()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        socksListener?.cancel(); socksListener = nil
        if bridgeFD >= 0 { close(bridgeFD); bridgeFD = -1 }
        if hevFD >= 0 {
            hev_socks5_tunnel_quit()
            close(hevFD); hevFD = -1
        }
        log("stopTunnel reason=\(reason.rawValue)")
        completionHandler()
    }

    static func route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        var bits: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        var octets: [String] = []
        for _ in 0..<4 {
            octets.append(String((bits >> 24) & 0xFF)); bits <<= 8
        }
        return NEIPv4Route(destinationAddress: String(parts[0]),
                           subnetMask: octets.joined(separator: "."))
    }

    // MARK: - hev 桥接

    private func startHevBridge() {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            log("socketpair failed"); return
        }
        hevFD = fds[0]
        bridgeFD = fds[1]
        var sz: Int32 = 4 * 1024 * 1024
        for fd in fds {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, socklen_t(MemoryLayout<Int32>.size))
        }

        let yaml = """
        tunnel:
          name: utun0
          mtu: 1500
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
                hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(buf.count), fds[0])
            }
            self?.log("hev exited rc=\(rc)")
        }
        thread.name = "hev"
        thread.start()

        // packetFlow → hev
        func readPackets() {
            guard running else { return }
            packetFlow.readPackets { [weak self] packets, protocols in
                guard let self = self, self.running else { return }
                for (i, pkt) in packets.enumerated() {
                    var out = Data()
                    let af = i < protocols.count ? UInt32(truncating: protocols[i]) : UInt32(AF_INET)
                    var type = af.bigEndian
                    withUnsafeBytes(of: &type) { out.append(contentsOf: $0) }
                    out.append(pkt)
                    let sent = out.withUnsafeBytes { buf in
                        send(self.bridgeFD, buf.baseAddress, buf.count, MSG_DONTWAIT)
                    }
                    if sent < 0 { self.log("send bridge error \(errno)") }
                }
                readPackets()
            }
        }
        readPackets()

        // hev → packetFlow
        let source = DispatchSource.makeReadSource(fileDescriptor: bridgeFD, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }
            // 非阻塞 drain，避免一次空事件后永久阻塞
            while true {
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = recv(self.bridgeFD, &buf, buf.count, MSG_DONTWAIT)
                guard n > 4 else { break }
                let type = buf.withUnsafeBytes { $0.load(as: UInt32.self) }
                let af = UInt32(bigEndian: type)
                let pkt = Self.fixChecksums(Data(buf[4..<n]))
                self.packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: af)])
            }
        }
        source.resume()
        self.bridgeSource = source

    }

    private var bridgeSource: DispatchSourceRead?

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
            self?.log("socks incoming")
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
            if let chunk = try await client.receive() {
                peek.append(chunk)
            }
            var sni = Self.parseSNI(peek) ?? Self.parseHTTPHost(peek)
            if sni == nil, let more = try await client.receive() {
                peek.append(more)
                sni = Self.parseSNI(peek) ?? Self.parseHTTPHost(peek)
            }
            let target = sni ?? host
            log("socks \(host):\(port) sni=\(sni ?? "-")")

            log("peek \(peek.count) bytes, dialing")

            let resid = store.resid(host: target, port: port)
            var upstream: ByteStream?
            if !resid.isEmpty, !token.isEmpty, let gw = gateways.first {
                do {
                    upstream = try await Gateway.dial(gateway: gw, serverName: serverName,
                                                      token: token, host: target,
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

            // 上游 → 客户端
            let back = Task { await Self.pipe(up, client, "t->c", log) }
            if !peek.isEmpty { try await up.send(peek) }
            // 客户端 → 上游（继续读取，直到 EOF）
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

        // IPv4 header
        p[10] = 0; p[11] = 0
        let ipc = cs(p[0..<ihl])
        p[10] = UInt8(ipc >> 8); p[11] = UInt8(ipc & 0xFF)

        let proto = p[9]
        let totalLen = min(p.count, Int(p[2]) << 8 | Int(p[3]))
        if (proto == 6 || proto == 17), totalLen >= ihl + 8 {
            let off = proto == 6 ? 16 : 6
            // 先清零校验和字段（lwIP 可能填 0xFFFF 作为 offload 哨兵），再计算
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
        } catch {
            log("\(label) error \(error)")
        }
        await to.closeWrite()
    }

    static func parseHTTPHost(_ data: Data) -> String? {
        guard data.count > 16 else { return nil }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("host:") {
                return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - TLS SNI

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
                let listLen = Int(d[j]) << 8 | Int(d[j+1]); j += 2
                guard j + 3 <= i + len, j + 3 + 0 <= i + len else { return nil }
                _ = listLen
                j += 1 // name_type
                let nameLen = Int(d[j]) << 8 | Int(d[j+1]); j += 2
                guard j + nameLen <= i + len else { return nil }
                return String(bytes: d[j..<(j+nameLen)], encoding: .utf8)
            }
            i += len
        }
        return nil
    }
}

// 超时辅助
func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T?) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = try await group.next()
        group.cancelAll()
        return result ?? nil
    }
}
