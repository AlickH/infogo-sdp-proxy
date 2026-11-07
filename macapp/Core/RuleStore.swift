import Foundation

struct Rule {
    var pattern: String   // 域名 / IP / CIDR / IP 段
    var resid: String
    var ports: String     // "443,8001" / "80/24-3300" / 空=不限
}

/// 资源规则表：官方策略表 + 内置 + 学习结果
final class RuleStore {
    private(set) var rules: [Rule] = []
    private var builtinRules: [Rule] = RuleStore.builtinRules
    private var configRules: [Rule] = []
    private var policyRules: [Rule] = []
    private var learnedRules: [Rule] = []
    private let lock = NSLock()

    static let builtinDirectDomains = ["app.cscec5b.com.cn"]

    static let builtinRules: [Rule] = [
        Rule(pattern: "bip.cscec5b.com.cn", resid: "135", ports: "443,8001,20558"),
        Rule(pattern: "oa.cscec5b.com.cn", resid: "241", ports: "443"),
        Rule(pattern: "oa.cscec5b.com.cn", resid: "194", ports: "9443"),
        Rule(pattern: "portal.cscec5b.com.cn", resid: "244", ports: "80,24-3300,4000-65534"),
        Rule(pattern: "erp.hnzjdc.com", resid: "191", ports: "9010-9023"),
    ]

    func replacePolicy(_ policy: [Rule]) {
        lock.lock(); defer { lock.unlock() }
        policyRules = policy
        rebuildLocked()
    }

    /// 合并配置中的 resources（与 Go 版一致：builtin → config → policy）
    func setConfigResources(_ entries: [ResourceEntry]) {
        lock.lock(); defer { lock.unlock() }
        configRules = entries.map { Rule(pattern: $0.domain, resid: $0.resid, ports: $0.ports ?? "") }
        rebuildLocked()
    }

    func addLearned(host: String, resid: String) {
        lock.lock(); defer { lock.unlock() }
        learnedRules.append(Rule(pattern: host, resid: resid, ports: ""))
        rebuildLocked()
    }

    private func rebuildLocked() {
        var out: [Rule] = []
        var seen = Set<String>()
        for r in builtinRules + configRules + policyRules + learnedRules {
            let key = "\(r.pattern.lowercased())|\(r.resid)|\(r.ports)"
            if seen.insert(key).inserted { out.append(r) }
        }
        rules = out
    }

    /// 仅按显式直连名单判断（规则生成用，不做 DNS 解析）
    func isExplicitDirect(_ host: String, directDomains: [String]) -> Bool {
        let h = host.lowercased()
        for d in (RuleStore.builtinDirectDomains + directDomains).map({ $0.lowercased() }) where !d.isEmpty {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }

    func snapshot() -> [Rule] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    /// 域名是否显式直连（公网入口）
    func isDirectDomain(_ host: String, directDomains: [String]) -> Bool {
        let h = host.lowercased()
        for d in (RuleStore.builtinDirectDomains + directDomains).map({ $0.lowercased() }) where !d.isEmpty {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        // 解析到 SDP 公网入口段（122.191.10.x）也直连
        if let ip = PublicDNS.resolveIPv4(h), ip.hasPrefix("122.191.10.") { return true }
        return false
    }

    /// 精确匹配资源 ID（域名最长后缀 + 端口校验）
    func resid(host: String, port: UInt16) -> String {
        lock.lock(); defer { lock.unlock() }
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        let ip = PublicDNS.isIPv4(h) ? h : nil
        var best = ""
        var bestLen = -1
        for r in rules {
            let p = r.pattern.lowercased().trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            guard portAllowed(r.ports, port) else { continue }

            if let ip = ip {
                if p.contains("/"), let (_, cidr) = parseCIDR(p), cidrContains(cidr, ip) {
                    return r.resid
                }
                if p.contains("-"), !p.contains("/"), ipInRange(p, ip) {
                    return r.resid
                }
                if p == ip { return r.resid }
                continue
            }
            if p.hasPrefix(".") {
                if h.hasSuffix(p) && p.count > bestLen { bestLen = p.count; best = r.resid }
            } else if p.contains(".") && (h == p || h.hasSuffix("." + p)) {
                if p.count > bestLen { bestLen = p.count; best = r.resid }
            }
        }
        return best
    }

    func hostKnown(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let h = host.lowercased()
        return rules.contains { r in
            let p = r.pattern.lowercased()
            return p == h || (p.hasPrefix(".") && h.hasSuffix(p))
        }
    }

    // MARK: - 端口与地址工具

    func portAllowed(_ spec: String, _ port: UInt16) -> Bool {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return true }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == "," })
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if p.contains("-") {
                let segs = p.split(separator: "-", maxSplits: 1)
                if segs.count == 2, let lo = Int(segs[0]), let hi = Int(segs[1]),
                   Int(port) >= lo && Int(port) <= hi { return true }
            } else if let v = Int(p), v == Int(port) { return true }
        }
        return false
    }

    private func parseCIDR(_ s: String) -> (String, (UInt32, UInt32))? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let bits = UInt32(parts[1]) else { return nil }
        guard let base = ipv4ToUInt(String(parts[0])) else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return (String(parts[0]), (base & mask, mask))
    }

    private func cidrContains(_ cidr: (UInt32, UInt32), _ ip: String) -> Bool {
        guard let v = ipv4ToUInt(ip) else { return false }
        return v & cidr.1 == cidr.0
    }

    private func ipInRange(_ range: String, _ ip: String) -> Bool {
        let parts = range.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let lo = ipv4ToUInt(String(parts[0])),
              let hi = ipv4ToUInt(String(parts[1])),
              let v = ipv4ToUInt(ip) else { return false }
        return v >= min(lo, hi) && v <= max(lo, hi)
    }

    private func ipv4ToUInt(_ s: String) -> UInt32? {
        let o = s.split(separator: ".").compactMap { UInt32($0) }
        guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return nil }
        return (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]
    }
}
