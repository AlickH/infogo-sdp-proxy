import Foundation
import NetworkExtension
import Network

/// Tailscale 引擎的桥接契约与网络设置辅助。
///
/// 合并后 Tailscale 不再是独立的系统扩展，而是 `MergedProvider` 里的一个引擎
/// （见 `Merged/TSEngine.swift`）。本文件只保留「与引擎实现解耦」所需的部分：
///
///   - `TailscaleRuntime` 协议：引擎要提供的最小能力集合
///   - `TailscaleRuntimeFactory`：引擎注入点（`Tools/TSBridgeRuntime.swift` 里
///     `registerTailscaleRuntimeBridge()` 会把真实的 Go 桥接实现注册进来）
///   - `TSBridgeSetup`：`-D TS_HAS_BRIDGE` 时触发一次注册
///   - `TSTunnelSettings`：把控制面下发的地址/路由/DNS 转成 `NEPacketTunnelNetworkSettings`
///   - `TSMessageRouter`：App ↔ 扩展消息通道的纯逻辑层（可脱离 NE 上下文自检）
///
/// 官方开源仓库是 `github.com/tailscale/tailscale`（`ipn` / `wgengine` /
/// `cmd/tailscaled`）；按其开源政策，Apple 平台的 NetworkExtension 宿主层闭源，
/// **没有官方公开的 Swift 桥接框架**，引擎适配层由构建方自行提供（本仓库是
/// `Tools/TSBridgeRuntime.swift` + `Vendor/Tsbridge.xcframework`）。
///
/// 未注册时引擎会明确以 `engineNotEmbedded` 失败，不会伪装成已连接。
/// 详见 README「Tailscale」章节。

// MARK: - 引擎桥接协议

/// Tailscale 引擎需要实现的最小能力集合。
///
/// `packetFlow` 在构造时注入：引擎从 `readPackets` 读取本机发往 tailnet 的 IP 包，
/// 经 WireGuard 封装后走 DERP/直连发出；收到的包用 `writePackets` 注入回网络栈。
protocol TailscaleRuntime: AnyObject {
    /// 启动控制面与数据面。
    /// - `configuration`: App 通过 `NETunnelProviderProtocol.providerConfiguration` 下发的字段
    /// - `applySettings`: 引擎在拿到控制面分配的地址后调用，用于设置/更新虚拟网卡路由与 DNS
    /// - `completion`: **必须**在首次 `applySettings` 完成后再调用，否则系统认为隧道建立失败
    func start(configuration: [String: Any],
               applySettings: @escaping (NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void,
               completion: @escaping (Error?) -> Void)

    /// 返回运行时状态 JSON（App 侧 `TSManager` 每 2s 拉取一次）。字段约定：
    /// ```json
    /// {
    ///   "backendState": "Running",          // NoState / NeedsLogin / Starting / Running / Stopped
    ///   "selfIPs": ["100.64.0.7"],           // 本机 Tailscale 地址
    ///   "authURL": "",                       // 待登录时的 SSO 链接；登录后留空
    ///   "tailnet": "example.ts.net",
    ///   "peers": [{ "name": "nas", "ip": "100.64.0.8",
    ///               "online": true, "direct": true, "os": "linux", "relay": "" }],
    ///   "rxBytes": 12345, "txBytes": 6789
    /// }
    /// ```
    func statusJSON() -> Data?

    /// 清除本机登录态，控制面会重新给出 AuthURL
    func logout()

    /// 触发交互式登录（`authKey` 留空时由 App 侧「登录」按钮调用）。
    /// 引擎随后会在 `statusJSON` 的 `authURL` 里给出 SSO 链接。
    func loginInteractive()

    /// 停止引擎并释放资源
    func stop(completion: @escaping () -> Void)
}

extension TailscaleRuntime {
    /// 未实现交互式登录的适配层退化为空操作（不影响预授权 authKey 流程）
    func loginInteractive() {}
}

enum TailscaleRuntimeError: LocalizedError {
    case invalidConfig
    case engineNotEmbedded

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Tailscale 配置无效（缺少合法的 Control URL）"
        case .engineNotEmbedded:
            return "TSNE 未链接 Tailscale 引擎：请用 TS_BRIDGE_SRC 注入 TailscaleRuntime 适配层"
        }
    }
}

/// 引擎实现的注入点。真实实现由 TSNE 构建目标里的适配器在启动前注册。
final class TailscaleRuntimeFactory {
    typealias Builder = (NEPacketTunnelFlow) -> TailscaleRuntime

    private static let lock = NSLock()
    private nonisolated(unsafe) static var builder: Builder?

    static func register(_ builder: @escaping Builder) {
        lock.lock(); defer { lock.unlock() }
        self.builder = builder
    }

    static func make(flow: NEPacketTunnelFlow) -> TailscaleRuntime? {
        lock.lock(); defer { lock.unlock() }
        return builder?(flow)
    }
}

/// 引擎适配层的注册钩子。
/// SDPNE 目标带 `-D TS_HAS_BRIDGE`；适配层需提供全局函数
/// `registerTailscaleRuntimeBridge()`，在其中调用 `TailscaleRuntimeFactory.register`。
/// 静态常量保证只注册一次。
enum TSBridgeSetup {
    private static let once: Void = {
        #if TS_HAS_BRIDGE
        registerTailscaleRuntimeBridge()
        #else
        NSLog("[TS] 未链接 Tailscale 引擎（未提供 TailscaleRuntime 适配层）")
        #endif
    }()

    static func registerIfNeeded() { _ = once }
}

// MARK: - 网络设置辅助

/// 把控制面下发的地址/路由/DNS 转成 Packet Tunnel 网络设置，供引擎适配器复用。
enum TSTunnelSettings {
    static func build(remoteAddress: String,
                      addresses: [String],
                      routes: [String],
                      dnsServers: [String],
                      matchDomain: String = "",
                      mtu: Int = 1280) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = NSNumber(value: max(576, min(mtu, 65535)))

        let ipv4 = NEIPv4Settings(
            addresses: addresses.filter { !$0.contains(":") },
            subnetMasks: Array(repeating: "255.255.255.255",
                               count: addresses.filter { !$0.contains(":") }.count)
        )
        let gateway = ipv4.addresses.first
        var included: [NEIPv4Route] = []
        for cidr in routes where !cidr.contains(":") {
            let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
            let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
            let route = NEIPv4Route(destinationAddress: parts[0], subnetMask: mask(prefix))
            // packet tunnel 里把网关指向虚拟接口地址，否则部分系统上路由不生效
            route.gatewayAddress = gateway
            included.append(route)
        }
        // 默认路由由 exit node 决定，交给引擎按需补充
        ipv4.includedRoutes = included
        settings.ipv4Settings = ipv4

        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            // 只把 tailnet 自己的域名交给 MagicDNS，其余查询仍走系统默认解析器
            // （WireGuard / SDPNE 已经提供了默认 DNS，不能整条抢过来）。
            if !matchDomain.isEmpty {
                // 不带 "~"：macOS 上 matchDomains 的条目本身就是「该域及其子域」的后缀匹配；
                // 加了 "~" 反而会被当成 search domain 挂到默认解析器上，
                // 导致 *.ts.net 的查询被发给 WireGuard 的 1.1.1.1 而不是 MagicDNS。
                dns.matchDomains = [matchDomain]
            }
            settings.dnsSettings = dns
        }
        return settings
    }

    /// CIDR 前缀长度 → 点分十进制子网掩码
    static func mask(_ prefix: Int) -> String {
        let p = max(0, min(prefix, 32))
        let bits: UInt32 = p == 0 ? 0 : UInt32.max << (32 - p)
        return "\((bits >> 24) & 255).\((bits >> 16) & 255).\((bits >> 8) & 255).\(bits & 255)"
    }
}

// MARK: - 消息路由

/// App ↔ 扩展消息通道的纯逻辑层：不继承 `NEPacketTunnelProvider`，
/// 因此可以在没有系统扩展上下文的环境里做自检（见 `Tools/TSTunnelSelfTest.swift`）。
struct TSMessageRouter {
    /// 由 provider 注入，返回当前引擎；未启动 / 未链接时为 nil
    var runtime: () -> TailscaleRuntime?

    func handle(_ messageData: Data) -> Data? {
        let cmd = String(data: messageData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch cmd {
        case "status":
            return runtime()?.statusJSON()
        case "logout":
            runtime()?.logout()
            return Data("ok".utf8)
        case "login":
            // App 侧「登录」按钮：让控制面重新生成 AuthURL（Status 里带出）
            runtime()?.loginInteractive()
            return Data("ok".utf8)
        case "ping":
            return Data("pong".utf8)
        default:
            NSLog("[TS] 未知 App 消息: %@", cmd)
            return nil
        }
    }
}
