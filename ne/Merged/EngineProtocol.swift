import Foundation
import NetworkExtension
import Darwin

/// 一个 IPv4 网段，用于把目的地址归到某条管道。
///
/// 只支持 IPv4 是刻意的：当前三条隧道声明的路由全是 IPv4
/// （SDP 172.30/16、10.240/12、122.191.10/24；WG 10.0.0.0/24；TS 100.64/10）。
struct IPPrefix {
    let address: UInt32
    let mask: UInt32
    let prefixLength: Int

    init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard let host = parts.first,
              let prefix = parts.count > 1 ? Int(parts[1]) : 32,
              (0...32).contains(prefix),
              let addr = Self.parseIP(String(host)) else { return nil }
        // addr 与 destination(of:) 都是「网络字节序的 4 字节按本机字节序读成 UInt32」，
        // 所以掩码也要字节交换，否则按位与会落在错误的字节上。
        let hostBits: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        let m = hostBits.byteSwapped
        self.address = addr & m
        self.mask = m
        self.prefixLength = prefix
    }

    func contains(_ ip: UInt32) -> Bool { (ip & mask) == address }

    static func parseIP(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return addr.s_addr
    }

    /// 网络字节序的 UInt32 → 点分十进制（仅用于诊断日志）
    static func string(_ netOrder: UInt32) -> String {
        var addr = in_addr(s_addr: netOrder)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// 从裸 IPv4 包里取目的地址（字节 16...19），返回值保持网络字节序
    static func destination(of packet: Data) -> UInt32? {
        guard packet.count >= 20, (packet[0] >> 4) == 4 else { return nil }
        return packet.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        }
    }

    /// 源地址（字节 12...15），仅用于诊断日志
    static func source(of packet: Data) -> UInt32? {
        guard packet.count >= 20, (packet[0] >> 4) == 4 else { return nil }
        return packet.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        }
    }
}

/// 一条可被分类器驱动的隧道引擎。
///
/// 合并前每个引擎各自是一个 `NEPacketTunnelProvider`，自己持有 packetFlow；
/// 合并后只保留「吃裸 IP 包 / 吐裸 IP 包」这部分，网络设置和 flow 由
/// `PacketDispatcher` 统一管理。
protocol TunnelEngine: AnyObject {
    var name: String { get }

    /// 该引擎负责的目的网段（最长前缀优先）
    var routes: [String] { get }

    /// 交给内核的虚拟网卡地址（CIDR），以及 DNS 设置
    var addresses: [String] { get }
    /// 不进入隧道的路由（如 127.0.0.1/32）
    var excludeRoutes: [String] { get }

    /// 本引擎自己发起外联时要连的目标（`host:port` 或裸 host）。
    ///
    /// 这些地址必须被排除出隧道，否则引擎的加密流量会被自己的 utun 吸回去：
    /// SystemExtension 时代由系统按每条 VPN 的 `serverAddress` 自动排除，
    /// 合并成一条隧道后系统无从得知，只能由引擎自己报上来。
    var outboundTargets: [String] { get }
    var dnsServers: [String] { get }
    var dnsMatchDomain: String { get }
    var mtu: Int { get }

    /// 只解析配置、把 `routes` / `excludeRoutes` / `addresses` / `dnsServers` / `mtu`
    /// 算出来，**不启动任何数据面**（不开 socket、不连网关、不建隧道）。
    ///
    /// 必须由 `MergedProvider` 在 `PacketDispatcher.register()` 与
    /// `buildSettings()` **之前**调用：这两个方法读的就是这些属性。
    /// 若等到 `start()` 才填充，`includedRoutes` 会是空数组——而 macOS 把
    /// 「空的 includedRoutes」当成「接管全部 IPv4 流量」，会装上默认路由，
    /// 连扩展自己要用的网关地址也一起吸进隧道（`excludeRoutes` 同样还是空的），
    /// 表现就是隧道显示已连接、但所有流量出不去。
    func prepare(config: [String: Any])

    /// 启动引擎；完成时所有后台读写循环都应已就绪
    func start(config: [String: Any], completion: @escaping (Error?) -> Void)

    /// 停止引擎并结束所有后台循环
    func stop()

    /// OS → 引擎
    func deliver(_ packet: Data)

    /// 注册「引擎 → OS」的回调（只会注册一次）
    func onOutbound(_ handler: @escaping (Data) -> Void)

    /// App 侧发来的控制消息（status / login / logout 等）
    func handleMessage(_ message: Data, completion: @escaping (Data?) -> Void)

    /// 周期性状态采样（用于诊断：握手/收发计数）。
    /// 默认空实现；只有 WG 这种「发出去了但收不到」的引擎需要。
    func logStatus(_ reason: String)

    /// 引擎在运行中发现地址 / 路由变化时调用。
    ///
    /// 目前只有 Tailscale 需要：`start()` 时控制面还没下发地址，只能用占位
    /// `100.64.0.254`；登录/连上之后才有真实 `100.x.y.z`，那时必须重建设置，
    /// 否则真实地址永远进不了 utun，回包会被内核丢掉。默认实现是空操作。
    func setNetworkChangeHandler(_ handler: @escaping () -> Void)
}

extension TunnelEngine {
    var excludeRoutes: [String] { [] }
    var outboundTargets: [String] { [] }
    func setNetworkChangeHandler(_ handler: @escaping () -> Void) {}
    func logStatus(_ reason: String) {}
}
