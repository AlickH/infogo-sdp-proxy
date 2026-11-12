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

    /// 从裸 IPv4 包里取目的地址（字节 16...19），返回值保持网络字节序
    static func destination(of packet: Data) -> UInt32? {
        guard packet.count >= 20, (packet[0] >> 4) == 4 else { return nil }
        return packet.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
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
    var dnsServers: [String] { get }
    var dnsMatchDomain: String { get }
    var mtu: Int { get }

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
}

extension TunnelEngine {
    var excludeRoutes: [String] { [] }
}
