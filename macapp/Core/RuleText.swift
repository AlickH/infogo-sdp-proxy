import Foundation

enum RuleText {
    static func surge(store: RuleStore, cfg: SDPConfig) -> String {
        var lines = [
            "# 由 SDP 代理自动生成（资源策略实时同步）",
            "# Surge:  RULE-SET,http://127.0.0.1:\(rulePort(cfg))/surge.list,CSCEC,no-resolve",
            "# 注意: sdp.cscec5b.com.cn 为控制通道, 需在规则集之前 DIRECT",
        ]
        var seen = Set<String>()
        for r in store.snapshot() {
            let p = r.pattern.lowercased()
            if p.isEmpty || seen.contains(p) { continue }
            if store.isDirectDomain(p, directDomains: cfg.directDomains ?? []) { continue }
            seen.insert(p)
            if p.contains("/") {
                lines.append("IP-CIDR,\(p),no-resolve")
            } else if p.contains("-") && p.filter({ $0 == "." }).count == 6 {
                let segs = p.split(separator: "-", maxSplits: 1)
                if segs.count == 2 {
                    for c in ipRangeToCIDRs(String(segs[0]), String(segs[1])) {
                        lines.append("IP-CIDR,\(c),no-resolve")
                    }
                }
            } else if PublicDNS.isIPv4(p) {
                lines.append("IP-CIDR,\(p)/32,no-resolve")
            } else if p.contains(".") {
                lines.append("DOMAIN-SUFFIX,\(p)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func clash(store: RuleStore, cfg: SDPConfig) -> String {
        var lines = ["# 由 SDP 代理自动生成（Clash classical rule-provider）"]
        var seen = Set<String>()
        for r in store.snapshot() {
            let p = r.pattern.lowercased()
            if p.isEmpty || seen.contains(p) { continue }
            if store.isDirectDomain(p, directDomains: cfg.directDomains ?? []) { continue }
            seen.insert(p)
            if p.contains("/") {
                lines.append("IP-CIDR,\(p),no-resolve")
            } else if p.contains("-") && p.filter({ $0 == "." }).count == 6 {
                let segs = p.split(separator: "-", maxSplits: 1)
                if segs.count == 2 {
                    for c in ipRangeToCIDRs(String(segs[0]), String(segs[1])) {
                        lines.append("IP-CIDR,\(c),no-resolve")
                    }
                }
            } else if PublicDNS.isIPv4(p) {
                lines.append("IP-CIDR,\(p)/32,no-resolve")
            } else if p.contains(".") {
                lines.append("DOMAIN-SUFFIX,\(p)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func pac(store: RuleStore, cfg: SDPConfig) -> String {
        var domains: [String] = []
        var ips: [String] = []
        var cidrs: [(String, String)] = []
        var seen = Set<String>()
        for r in store.snapshot() {
            let p = r.pattern.lowercased()
            if p.isEmpty || seen.contains(p) { continue }
            if store.isDirectDomain(p, directDomains: cfg.directDomains ?? []) { continue }
            seen.insert(p)
            if p.contains("/") {
                if let (ip, mask) = cidrToPac(p) { cidrs.append((ip, mask)) }
            } else if p.contains("-") && p.filter({ $0 == "." }).count == 6 {
                let segs = p.split(separator: "-", maxSplits: 1)
                if segs.count == 2 {
                    for c in ipRangeToCIDRs(String(segs[0]), String(segs[1])) {
                        if let (ip, mask) = cidrToPac(c) { cidrs.append((ip, mask)) }
                    }
                }
            } else if PublicDNS.isIPv4(p) {
                ips.append(p)
            } else if p.contains(".") {
                domains.append(p)
            }
        }
        let (_, httpPort) = SDPConfig.splitHostPort(cfg.httpListen)
        let proxy = "PROXY 127.0.0.1:\(httpPort)"
        var js = "var DOMAINS = [\(quoted(domains))];\n"
        js += "var IPS = [\(quoted(ips))];\n"
        js += "var CIDRS = [\(cidrs.map { "[\"\($0.0)\",\"\($0.1)\"]" }.joined(separator: ","))];\n\n"
        js += """
        function isIPv4(h){return /^(\\d{1,3}\\.){3}\\d{1,3}$/.test(h);}
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (host === "localhost" || host === "127.0.0.1") return "DIRECT";
          if (isInNet(host, "127.0.0.0", "255.0.0.0")) return "DIRECT";
          if (host === "sdp.cscec5b.com.cn") return "DIRECT";
          if (host === "app.cscec5b.com.cn") return "DIRECT";
          for (var i = 0; i < DOMAINS.length; i++) {
            var d = DOMAINS[i];
            if (host === d || (host.length > d.length && host.slice(-(d.length+1)) === "." + d))
              return "\(proxy)";
          }
          if (isIPv4(host)) {
            for (var j = 0; j < IPS.length; j++) if (host === IPS[j]) return "\(proxy)";
            for (var k = 0; k < CIDRS.length; k++) if (isInNet(host, CIDRS[k][0], CIDRS[k][1])) return "\(proxy)";
          }
          return "DIRECT";
        }
        """
        return js
    }

    // MARK: - helpers

    static func rulePort(_ cfg: SDPConfig) -> UInt16 {
        SDPConfig.splitHostPort(cfg.uiListen).1
    }

    private static func quoted(_ arr: [String]) -> String {
        arr.map { "\"\($0)\"" }.joined(separator: ",")
    }

    private static func cidrToPac(_ s: String) -> (String, String)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let bits = UInt32(parts[1]),
              let base = ipv4ToUInt(String(parts[0])) else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return (String(parts[0]), uintToIPv4(mask))
    }

    static func ipRangeToCIDRs(_ start: String, _ end: String) -> [String] {
        guard let s = ipv4ToUInt(start), let e = ipv4ToUInt(end) else { return [] }
        var lo = min(s, e), hi = max(s, e)
        var out: [String] = []
        while lo <= hi && out.count < 512 {
            var bits: UInt32 = 32
            while bits > 0 {
                let mask: UInt32 = ~UInt32(0) << (32 - (bits - 1))
                if lo & mask != lo { break }
                bits -= 1
            }
            while bits < 32 {
                let blockEnd = lo &+ (UInt32(1) << (32 - bits)) &- 1
                if blockEnd > hi { bits += 1; continue }
                break
            }
            let size = UInt32(1) << (32 - bits)
            out.append("\(uintToIPv4(lo))/\(bits)")
            if size == 0 { break }
            lo = lo &+ size
        }
        return out
    }

    private static func ipv4ToUInt(_ s: String) -> UInt32? {
        let o = s.split(separator: ".").compactMap { UInt32($0) }
        guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return nil }
        return (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]
    }

    private static func uintToIPv4(_ v: UInt32) -> String {
        "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
    }
}
