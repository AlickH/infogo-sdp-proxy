import Foundation
import NetworkExtension
import Darwin

/// Tailscale NE 宿主层自检：不需要签名、不需要真实引擎、不需要 root。
/// 用 swiftc 同时编入 `ne/TSProvider.swift` 与 `macapp/TSManager.swift` 后运行，
/// 验证 App 侧与扩展侧的协议契约是否一致。命令见 README「宿主层自检」。
@main
struct TSTunnelSelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool) {
        if ok {
            passed += 1
            print("  PASS  \(name)")
        } else {
            failed += 1
            print("  FAIL  \(name)")
        }
    }

    static func main() {
        // 关闭 stdout 缓冲，实时输出每项检查结果
        setvbuf(stdout, nil, _IONBF, 0)
        print("=== Tailscale NE 宿主层自检 ===")

        // 1) CIDR 前缀 → 点分十进制掩码
        print("[1] CIDR 掩码")
        check("/0  -> 0.0.0.0", TSTunnelSettings.mask(0) == "0.0.0.0")
        check("/10 -> 255.192.0.0", TSTunnelSettings.mask(10) == "255.192.0.0")
        check("/24 -> 255.255.255.0", TSTunnelSettings.mask(24) == "255.255.255.0")
        check("/32 -> 255.255.255.255", TSTunnelSettings.mask(32) == "255.255.255.255")
        check("越界钳位 /40 -> /32", TSTunnelSettings.mask(40) == "255.255.255.255")

        // 2) 网络设置构造
        print("[2] TSTunnelSettings.build")
        let settings = TSTunnelSettings.build(
            remoteAddress: "controlplane.tailscale.com",
            addresses: ["100.64.0.7", "fd7a:115c:a1e0::7"],
            routes: ["100.64.0.0/10", "10.0.0.0/24", "fd7a::/64"],
            dnsServers: ["100.100.100.100"],
            mtu: 1280)
        check("MTU = 1280", settings.mtu?.intValue == 1280)
        check("IPv4 地址过滤掉 IPv6", settings.ipv4Settings?.addresses == ["100.64.0.7"])
        check("IPv4 路由过滤掉 IPv6 段（2 条）", settings.ipv4Settings?.includedRoutes?.count == 2)
        check("100.64/10 掩码正确",
              settings.ipv4Settings?.includedRoutes?.first?.destinationSubnetMask == "255.192.0.0")
        check("路由网关指向虚拟地址",
              settings.ipv4Settings?.includedRoutes?.first?.gatewayAddress == "100.64.0.7")
        check("MagicDNS 服务器", settings.dnsSettings?.servers == ["100.100.100.100"])
        check("MTU 下限钳到 576",
              TSTunnelSettings.build(remoteAddress: "x", addresses: [], routes: [],
                                     dnsServers: [], mtu: 100).mtu?.intValue == 576)

        // 3) 配置模型与持久化
        print("[3] TSConfig / TSStore")
        let cfg = TSConfig()
        check("默认控制面", cfg.controlURL == "https://controlplane.tailscale.com")
        check("默认捕获 100.64/10", cfg.routes == "100.64.0.0/10")
        check("默认 MTU 1280", cfg.mtu == "1280")
        check("默认交互式登录", cfg.loginMode == "交互式登录")
        check("默认配置有效", cfg.valid)
        var bad = cfg
        bad.controlURL = "not a url"
        check("非法 Control URL 被拒绝", !bad.valid)
        var headscale = cfg
        headscale.controlURL = "https://headscale.example.com"
        check("Headscale 地址有效", headscale.valid)
        check("displayName 回退到 host", headscale.displayName == "headscale.example.com")
        let storeData = try! JSONEncoder().encode(TSStore(configs: [cfg, headscale], activeID: cfg.id))
        let store = try! JSONDecoder().decode(TSStore.self, from: storeData)
        check("TSStore Codable 往返", store.configs.count == 2 && store.activeID == cfg.id)

        // 4) App ↔ 扩展 status JSON 契约（用 TSManager 的真实类型解码）
        print("[4] status JSON 契约")
        let json = """
        {"backendState":"NeedsLogin","selfIPs":["100.64.0.7"],
         "authURL":"https://login.tailscale.com/a/abc123",
         "tailnet":"example.ts.net",
         "peers":[{"name":"nas","ip":"100.64.0.8","online":true,"direct":true,"os":"linux","relay":""},
                  {"name":"phone","ip":"100.64.0.9","online":false,"direct":false,"os":"iOS","relay":""}],
         "rxBytes":12345,"txBytes":6789}
        """
        let decoded = try? JSONDecoder().decode(TSRuntimeStatus.self, from: Data(json.utf8))
        check("可解码", decoded != nil)
        check("backendState", decoded?.backendState == "NeedsLogin")
        check("authURL", decoded?.authURL == "https://login.tailscale.com/a/abc123")
        check("selfIPs", decoded?.selfIPs == ["100.64.0.7"])
        check("peers 2 个", decoded?.peers.count == 2)
        check("peer 直连标记", decoded?.peers.first?.direct == true)
        check("rx/tx 字节数", decoded?.rxBytes == 12345 && decoded?.txBytes == 6789)
        let partial = try? JSONDecoder().decode(TSRuntimeStatus.self, from: Data("{}".utf8))
        check("缺字段时回落默认值", partial?.backendState == "" && partial?.peers.isEmpty == true)

        // 5) 消息路由与缺引擎行为
        print("[5] TSMessageRouter 消息通道")
        let noEngine = TSMessageRouter(runtime: { nil })
        check("ping -> pong",
              noEngine.handle(Data("ping".utf8)).flatMap { String(data: $0, encoding: .utf8) } == "pong")
        check("未启动引擎时 status -> nil", noEngine.handle(Data("status".utf8)) == nil)
        check("logout -> ok",
              noEngine.handle(Data("logout".utf8)).flatMap { String(data: $0, encoding: .utf8) } == "ok")
        check("未知命令 -> nil", noEngine.handle(Data("bogus".utf8)) == nil)
        check("命令容忍首尾空白", noEngine.handle(Data("  ping \n".utf8)) != nil)
        check("engineNotEmbedded 文案指向 TS_BRIDGE_SRC",
              TailscaleRuntimeError.engineNotEmbedded.errorDescription?.contains("TS_BRIDGE_SRC") == true)

        // 6) Mock 引擎全生命周期
        print("[6] Mock 引擎 start / status / logout / stop")
        let mock = MockTailscaleRuntime()
        let router = TSMessageRouter(runtime: { mock })
        var settingsApplied = false
        var startError: Error?
        mock.start(configuration: ["controlURL": "https://controlplane.tailscale.com"],
                   applySettings: { settings, done in
                       settingsApplied = settings.ipv4Settings?.includedRoutes?.count == 1
                           && settings.dnsSettings?.servers == ["100.100.100.100"]
                       done(nil)
                   },
                   completion: { startError = $0 })
        check("start 无错误", startError == nil)
        check("start 下发网络设置", settingsApplied)
        let statusData = router.handle(Data("status".utf8))
        let running = statusData.flatMap { try? JSONDecoder().decode(TSRuntimeStatus.self, from: $0) }
        check("status 可被 App 侧类型解码", running?.backendState == "Running")
        check("status 带上本机 IP", running?.selfIPs == ["100.64.0.7"])
        _ = router.handle(Data("logout".utf8))
        check("logout 透传到引擎", mock.loggedOut)
        mock.stop { }
        check("stop 透传到引擎", mock.stopped)

        print("=== 结果: \(passed) passed, \(failed) failed ===")
        exit(failed == 0 ? 0 : 1)
    }
}

/// 自检用的引擎替身：只验证协议调用链，不做任何网络 I/O。
/// `NEPacketTunnelProvider` 不能在非扩展环境实例化，所以消息通道测的是
/// `TSMessageRouter` 而不是直接构造 `TSProvider`。
private final class MockTailscaleRuntime: TailscaleRuntime {
    var loggedOut = false
    var stopped = false

    func start(configuration: [String: Any],
               applySettings: @escaping (NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void,
               completion: @escaping (Error?) -> Void) {
        let settings = TSTunnelSettings.build(
            remoteAddress: (configuration["controlURL"] as? String) ?? "controlplane.tailscale.com",
            addresses: ["100.64.0.7"],
            routes: ["100.64.0.0/10"],
            dnsServers: ["100.100.100.100"],
            mtu: 1280)
        applySettings(settings) { completion($0) }
    }

    func statusJSON() -> Data? {
        let json = """
        {"backendState":"Running","selfIPs":["100.64.0.7"],"authURL":"","tailnet":"example.ts.net",
         "peers":[],"rxBytes":0,"txBytes":0}
        """
        return Data(json.utf8)
    }

    func logout() { loggedOut = true }

    func stop(completion: @escaping () -> Void) {
        stopped = true
        completion()
    }
}
