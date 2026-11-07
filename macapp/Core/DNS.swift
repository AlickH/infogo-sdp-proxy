import Foundation

/// 极简 DNS 解析（UDP），默认走 223.5.5.5，避开系统 fake-IP
enum PublicDNS {
    static func resolveIPv4(_ host: String, server: String = "223.5.5.5", timeout: TimeInterval = 3) -> String? {
        // 若本身是 IP，直接返回
        if isIPv4(host) { return host }
        guard let query = buildQuery(host) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let sent = withUnsafePointer(to: &addr) { ptr -> Int in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                query.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }

        var resp = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &resp, resp.count, 0)
        guard n > 12 else { return nil }
        resp = Array(resp.prefix(n))
        return parseA(resp)
    }

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    private static func buildQuery(_ host: String) -> Data? {
        var d = Data()
        d.append(contentsOf: [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in host.split(separator: ".") {
            guard let bytes = label.data(using: .utf8), bytes.count < 64 else { return nil }
            d.append(UInt8(bytes.count))
            d.append(bytes)
        }
        d.append(0x00)
        d.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // A, IN
        return d
    }

    private static func parseA(_ p: [UInt8]) -> String? {
        var i = 12
        func skipName() {
            while i < p.count {
                let len = Int(p[i])
                if len == 0 { i += 1; return }
                if len & 0xC0 == 0xC0 { i += 2; return }
                i += 1 + len
            }
        }
        guard i + 4 <= p.count else { return nil }
        i += 4 // QTYPE/QCLASS
        let ancount = Int(p[6]) << 8 | Int(p[7])
        for _ in 0..<ancount {
            skipName()
            guard i + 10 <= p.count else { return nil }
            let type = Int(p[i]) << 8 | Int(p[i+1])
            let rdlen = Int(p[i+8]) << 8 | Int(p[i+9])
            i += 10
            if type == 1 && rdlen == 4 && i + 4 <= p.count {
                return "\(p[i]).\(p[i+1]).\(p[i+2]).\(p[i+3])"
            }
            i += rdlen
        }
        return nil
    }
}
