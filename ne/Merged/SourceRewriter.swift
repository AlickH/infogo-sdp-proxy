import Foundation
import Darwin

/// 三层隧道（WireGuard）的**双向地址转换**。
///
/// ## 要解决的矛盾
///
/// 单 utun 上内核只会给应用的连接挑隧道自己的地址 `198.19.0.1` 做源。
/// 但 WireGuard 对端只认协议内的本机地址 `10.0.0.3`：
///
/// - 不改写：对端收到源 `198.19.0.1`，它没有这个地址，不回包
/// - 只改出向：对端回给 `10.0.0.3`，内核发现这个目的地址不属于任何已建立
///   的连接（连接是 `198.19.0.1` 发起的），直接回 RST
///
/// 抓包实测的第三条正是 RST：
/// ```
/// 198.19.0.1 > 10.0.0.2:5666  SYN
/// 10.0.0.2   > 10.0.0.3:5666  SYN-ACK
/// 10.0.0.3   > 10.0.0.2:5666  R      ← 内核重置
/// ```
///
/// ## 解法
///
/// 做完整的双向转换，让两侧各自看到的地址始终一致：
/// - OS → 引擎：源 `198.19.0.1` → `10.0.0.3`
/// - 引擎 → OS：目的 `10.0.0.3` → `198.19.0.1`
///
/// 内核侧看到的连接自始至终是 `198.19.0.1`，WireGuard 隧道内自始至终是
/// `10.0.0.3`。这正是 mihomo/Clash 那种用户态协议栈天然具备的行为。
enum SourceRewriter {
    /// 改写源地址（OS → 引擎方向）。
    /// 返回 nil 表示无需处理（已经是目标地址）或无法处理（非 IPv4）。
    static func rewrite(_ packet: Data, source to: String) -> Data? {
        replace(packet, ipFrom: 12, ipTo: 16, with: to)
    }

    /// 改写目的地址（引擎 → OS 方向，NAT 还原）。
    /// 返回 nil 表示无需处理或无法处理。
    static func rewrite(_ packet: Data, destination to: String) -> Data? {
        replace(packet, ipFrom: 16, ipTo: 20, with: to)
    }

    /// 把 IP 头里 `[ipFrom, ipTo)` 这 4 字节换成 `to`，并重算校验和。
    private static func replace(_ packet: Data, ipFrom: Int, ipTo: Int, with to: String) -> Data? {
        var p = [UInt8](packet)
        guard p.count >= 20, (p[0] >> 4) == 4 else { return nil }
        let ihl = Int(p[0] & 0x0F) * 4
        guard p.count >= ihl, p.count >= ipTo else { return nil }

        var addr = in_addr()
        guard to.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }

        let target = withUnsafeBytes(of: addr.s_addr) { Array($0) }
        if p[ipFrom] == target[0], p[ipFrom + 1] == target[1],
           p[ipFrom + 2] == target[2], p[ipFrom + 3] == target[3] {
            return nil
        }
        p[ipFrom] = target[0]; p[ipFrom + 1] = target[1]
        p[ipFrom + 2] = target[2]; p[ipFrom + 3] = target[3]

        return SDPEngine.fixChecksums(Data(p))
    }
}
