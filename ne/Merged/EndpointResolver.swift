import Foundation
import Darwin

/// 把引擎自己的「外联目标」解析成真实 IP，并作为 `excludedRoutes` 交给内核。
///
/// 为什么必须有这一步：合并成一条隧道后，网络设置里装的是「接管哪些网段」。
/// 三个引擎的外联流量（SDP 网关 TCP、WG 的加密 UDP、TS 的 DERP/controlplane）
/// 全部由扩展进程自己发起，如果这些目标落在隧道接管的范围内，就会被自己的
/// utun 吸回去——包发出去再也收不回来，表现为握手每几秒重来一次、`rx` 永远是 0。
///
/// SystemExtension 时代系统会按每条 VPN 的 `serverAddress` 自动做这件事；
/// 合并后 `serverAddress` 只有一个字符串，系统无从得知三个引擎各自的真实目标，
/// 所以必须在这里显式补上。
enum EndpointResolver {
    /// 解析一个已配置的 `<host>:<port>` 或裸 host 里的主机名。
    /// 主机名会先经系统 DNS 解析成 IP；解析失败时返回空数组（不制造假排除项）。
    static func resolveHosts(_ targets: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in targets {
            let host = hostPart(raw)
            guard !host.isEmpty else { continue }
            for ip in resolve(host) where seen.insert(ip).inserted {
                out.append(ip)
            }
        }
        return out
    }

    /// `1.2.3.4:80` / `[::1]:80` / `host` → host
    private static func hostPart(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }
        if t.hasPrefix("[") {
            if let close = t.firstIndex(of: "]") {
                return String(t[t.index(after: t.startIndex)..<close])
            }
            return t
        }
        // 只有一个冒号且右侧是端口时，剥掉端口；IPv6 裸地址有多个冒号，保留原样
        if let colon = t.lastIndex(of: ":"), t.filter({ $0 == ":" }).count == 1 {
            return String(t[..<colon])
        }
        return t
    }

    private static func resolve(_ host: String) -> [String] {
        if isIPv4(host) || isIPv6(host) { return [host] }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
            return []
        }
        defer { freeaddrinfo(head) }

        var ips: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let cur = node {
            if let sa = cur.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buf)
                    if !ip.isEmpty { ips.append(ip) }
                }
            }
            node = cur.pointee.ai_next
        }
        return ips
    }

    private static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &a) } == 1
    }

    private static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &a) } == 1
    }
}
