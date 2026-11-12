import Foundation
import NetworkExtension
import Tsbridge

/// 调用 `Tsbridge.xcframework` 的 `TailscaleRuntime` 实现，完成
/// `NEPacketTunnelFlow` ↔ Tailscale 引擎的裸 IP 包双向搬运。
///
/// 数据面链路：
/// - OS → Go：`flow.readPackets` → `TsbridgeDeliverInboundPacket`
///   → Go `packetTunnelDevice.Read` → tstun.Wrapper → wireguard-go → magicsock
/// - Go → OS：解密后的包 → Go `packetTunnelDevice.Write`
///   → `TsbridgeReadOutboundPacket` → `flow.writePackets`
///
/// 包格式是**裸 IP 包**（无 utun 的 4 字节 AF 头），协议族由首字节高 4 位判定。
///
/// 构建：
/// ```bash
/// ./scripts/build-tsbridge.sh
/// TS_BRIDGE_SRC=Tools/TSBridgeRuntime.swift \
/// TS_BRIDGE_FWK=/tmp/Tsbridge.xcframework \
///   ./scripts/build-tsne.sh
/// ```
final class TSBridgeRuntime: TailscaleRuntime {
    private let flow: NEPacketTunnelFlow
    /// true = 独立扩展模式，自己驱动 packetFlow；
    /// false = 合并模式，包由 PacketDispatcher 通过 deliver()/setOutboundHandler() 搬运。
    private let ownsFlow: Bool
    private var outboundHandler: ((Data) -> Void)?
    private let lock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopped }
        set { lock.lock(); defer { lock.unlock() }; _stopped = newValue }
    }

    /// 登录完成前使用的占位地址：只用于让隧道先建立，不接管任何流量
    private static let placeholderAddress = "100.64.0.254"
    /// `NEPacketTunnelNetworkSettings.tunnelRemoteAddress` 必须是**合法 IP**，
    /// 之前误传了 controlURL 的域名（controlplane.tailscale.com），
    /// 系统会直接以 "Invalid NETunnelNetworkSettings tunnelRemoteAddress" 拒绝，隧道起不来。
    /// 用 Tailscale 自己的 MagicDNS 地址作为对端地址。
    private static let tunnelRemoteAddress = "100.100.100.100"
    private var pendingConfiguration: [String: Any] = [:]
    private var applySettingsRef: ((NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void)?
    private var didApplyRealSettings = false
    /// 正在提交真实设置（避免每 2s 的 status 轮询重复提交）
    private var upgrading = false

    init(packetFlow: NEPacketTunnelFlow, ownsFlow: Bool = true) {
        self.flow = packetFlow
        self.ownsFlow = ownsFlow
    }

    /// 合并模式：OS → 引擎
    func deliver(_ packet: Data) {
        var err: NSError?
        if !TsbridgeDeliverInboundPacket(packet, &err) {
            NSLog("[TS] inbound 丢包: %@", err?.localizedDescription ?? "closed")
        }
    }

    /// 合并模式：注册「引擎 → OS」回调
    func setOutboundHandler(_ handler: @escaping (Data) -> Void) {
        outboundHandler = handler
    }

    func start(configuration: [String: Any],
               applySettings: @escaping (NEPacketTunnelNetworkSettings, @escaping (Error?) -> Void) -> Void,
               completion: @escaping (Error?) -> Void) {
        let cfg: [String: Any] = [
            "hostname": configuration["hostname"] as? String ?? "",
            "authKey": configuration["authKey"] as? String ?? "",
            "controlURL": configuration["controlURL"] as? String ?? "",
            "stateDir": Self.stateDir(),
            "ephemeral": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg),
              let json = String(data: data, encoding: .utf8) else {
            completion(TSBridgeError.invalidConfig)
            return
        }
        // gobind 生成的是 C 函数，NSError** 不导入成 Swift throws，需显式传 NSErrorPointer。
        var startErr: NSError?
        guard TsbridgeStart(json, &startErr) else {
            completion(startErr ?? TSBridgeError.invalidConfig)
            return
        }

        pendingConfiguration = configuration
        applySettingsRef = applySettings

        let ips = Self.selfIPs()
        if ips.isEmpty {
            // 交互式登录路径：此刻还没登录，控制面尚未分配 100.x 地址。
            // 若拿空地址去建设置，setTunnelNetworkSettings 会失败、隧道起不来，
            // App 也就永远拿不到 authURL。这里先建一条「空隧道」——
            // 占位地址 + 不接管任何路由/DNS——让隧道先跑起来，
            // 等登录完成、地址下发后再由 statusJSON 触发一次真实设置。
            let placeholder = TSTunnelSettings.build(
                remoteAddress: Self.tunnelRemoteAddress,
                addresses: [Self.placeholderAddress],
                routes: [],
                dnsServers: [],
                mtu: (configuration["mtu"] as? Int) ?? 1280)
            Self.diag("start: 尚未登录，先建占位隧道")
            NSLog("[TS] 尚未登录：先建立占位隧道，等待授权后切换真实地址")
            applySettings(placeholder) { [weak self] err in
                guard let self = self, err == nil else {
                    completion(err)
                    return
                }
                self.startPacketLoops()
                completion(nil)
            }
            return
        }

        let routes = (configuration["routes"] as? [String])?.filter { !$0.isEmpty }
            ?? ["100.64.0.0/10"]
        let acceptDNS = configuration["acceptDNS"] as? Bool ?? true
        let suffix = Self.tailnetSuffix()
        Self.diag("start: ips=\(ips.joined(separator: ",")) suffix=\(suffix) acceptDNS=\(acceptDNS)")
        // 刚连上时 backend 可能还是 Starting，MagicDNSSuffix 尚未下发。
        // 这种情况下先不锁死，留给 upgradeSettingsIfReady() 补一次带 split DNS 的设置。
        didApplyRealSettings = !(acceptDNS && suffix.isEmpty)
        let dns = acceptDNS ? ["100.100.100.100"] : []   // MagicDNS
        let settings = TSTunnelSettings.build(
            remoteAddress: Self.tunnelRemoteAddress,
            addresses: ips,
            routes: routes,
            dnsServers: dns,
            matchDomain: suffix,
            mtu: (configuration["mtu"] as? Int) ?? 1280)

        // 必须等 setTunnelNetworkSettings 完成后再开始搬包，否则虚拟网卡尚未建立。
        applySettings(settings) { [weak self] err in
            guard let self = self, err == nil else {
                completion(err)
                return
            }
            self.startPacketLoops()
            completion(nil)
        }
    }

    /// 登录完成、控制面下发地址后，把占位隧道升级为真实 tailnet 设置（只做一次）
    private func upgradeSettingsIfReady() {
        guard !didApplyRealSettings, !upgrading else { return }
        let ips = Self.selfIPs()
        guard !ips.isEmpty, let apply = applySettingsRef else { return }

        let cfg = pendingConfiguration
        let routes = (cfg["routes"] as? [String])?.filter { !$0.isEmpty } ?? ["100.64.0.0/10"]
        let acceptDNS = cfg["acceptDNS"] as? Bool ?? true
        let suffix = Self.tailnetSuffix()
        // 没有 tailnet 后缀就配不出 split DNS；此时不置位 didApplyRealSettings，等下一轮轮询。
        if acceptDNS && suffix.isEmpty { return }
        upgrading = true
        let settings = TSTunnelSettings.build(
            remoteAddress: Self.tunnelRemoteAddress,
            addresses: ips,
            routes: routes,
            dnsServers: acceptDNS ? ["100.100.100.100"] : [],
            matchDomain: suffix,
            mtu: (cfg["mtu"] as? Int) ?? 1280)
        Self.diag("upgrade: ips=\(ips.joined(separator: ",")) suffix=\(suffix) routes=\(routes)")
        NSLog("[TS] 登录完成，切换 tailnet 地址 %@，MagicDNS 域 %@",
              ips.joined(separator: ","), suffix.isEmpty ? "(无)" : suffix)
        apply(settings) { [weak self] err in
            guard let self = self else { return }
            self.upgrading = false
            if let err = err {
                // 失败就保持占位状态，下一轮 status 轮询会重试
                NSLog("[TS] 应用 tailnet 网络设置失败: %@", err.localizedDescription)
            } else {
                self.didApplyRealSettings = true
                NSLog("[TS] tailnet 网络设置已生效")
            }
        }
    }

    private func startPacketLoops() {
        // 合并模式下 OS→Go 由 dispatcher 调 deliver()，这里不注册 readPackets
        if ownsFlow {
        // OS → Go：每次回调后重新注册 readPackets，形成持续读取循环
        func pump() {
            flow.readPackets { [weak self] packets, _ in
                guard let self = self, !self.stopped else { return }
                for p in packets {
                    var err: NSError?
                    if !TsbridgeDeliverInboundPacket(p, &err) {
                        // 队列满或设备已关闭：丢弃单包，不中断循环
                        NSLog("[TS] inbound 丢包: %@", err?.localizedDescription ?? "closed")
                    }
                }
                if !self.stopped { pump() }
            }
        }
        pump()
        }

        // Go → OS：阻塞读取 Go 侧 Write 产出的包并写回虚拟网卡
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            while !self.stopped {
                guard let pkt = TsbridgeReadOutboundPacket() else { break }
                let bytes = pkt as Data
                guard !bytes.isEmpty else { continue }
                // 裸 IP 包首字节高 4 位：4 = IPv4, 6 = IPv6
                let version = (bytes.first ?? 0) >> 4
                let af: NSNumber = version == 6 ? 30 : 2   // AF_INET6 = 30, AF_INET = 2
                if self.ownsFlow {
                    self.flow.writePackets([bytes], withProtocols: [af])
                } else {
                    self.outboundHandler?(bytes)
                }
            }
        }
    }

    func statusJSON() -> Data? {
        // 登录完成后控制面才有 100.x 地址，这里顺带把占位隧道升级为真实设置
        upgradeSettingsIfReady()
        return TsbridgeStatus().data(using: .utf8)
    }

    func logout() {
        var err: NSError?
        if !TsbridgeLogout(&err) { Self.logBridgeError("logout", err) }
    }

    func stop(completion: @escaping () -> Void) {
        stopped = true
        var err: NSError?
        if !TsbridgeStop(&err) { Self.logBridgeError("stop", err) }
        completion()
    }

    /// 交互式登录（控制面随后会在 Status 里给出 authURL）
    func loginInteractive() {
        var err: NSError?
        if !TsbridgeLoginInteractive(&err) { Self.logBridgeError("login", err) }
    }

    private static func logBridgeError(_ op: String, _ err: NSError?) {
        NSLog("[TS] Tsbridge %@ 失败: %@", op, err?.localizedDescription ?? "unknown")
    }

    private enum TSBridgeError: LocalizedError {
        case invalidConfig
        var errorDescription: String? { "TSBridgeRuntime: 配置序列化失败" }
    }

    /// 系统扩展以 root 运行时的固定数据目录。
    ///
    /// 不能用 `containerURL(forSecurityApplicationGroupIdentifier:)`——App Group 容器
    /// 只对 App 沙盒上下文有效，在系统扩展进程里返回 **nil**，之前退化成
    /// `NSTemporaryDirectory()`，临时目录被系统清理后节点就掉登录、必须重新授权。
    /// 这里和 `SharedToken` 一样走机器级固定路径（扩展以 root 运行，可写）。
    private static let dataDir = URL(fileURLWithPath: "/Library/Application Support/SDPProxy",
                                     isDirectory: true)

    private static func ensureDataDir() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataDir.path) {
            try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        }
        // 目录可能由旧版本以 0700 建出来，这里每次都纠正一次，
        // 保证诊断日志可读；含私钥的 tsnet/ 子目录仍单独收紧到 0700。
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dataDir.path)
        return dataDir
    }

    /// 诊断日志：系统扩展里的 NSLog 在统一日志里看不到（被 NE 过滤），
    /// 所以把关键状态追加写进固定目录，方便从 shell 直接查看。
    static func diag(_ msg: String) {
        let url = ensureDataDir().appendingPathComponent("ts-diag.log")
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + msg + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            _ = try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: url.path)
        }
    }

    private static func stateDir() -> String {
        let dst = ensureDataDir().appendingPathComponent("tsnet", isDirectory: true)
        migrateLegacyStateIfNeeded(to: dst)
        try? FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dst.path
    }

    /// 老版本把 tsnet 状态放在 `NSTemporaryDirectory()/sdp-tsnet`。
    /// 首次升级到新路径时搬一次，避免用户被迫重新登录。
    private static func migrateLegacyStateIfNeeded(to dst: URL) {
        let fm = FileManager.default
        // 目标已有内容就不动
        if let existing = try? fm.contentsOfDirectory(atPath: dst.path), !existing.isEmpty {
            return
        }
        let legacy = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sdp-tsnet", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path),
              let files = try? fm.contentsOfDirectory(atPath: legacy.path),
              !files.isEmpty else { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        for f in files {
            let src = legacy.appendingPathComponent(f)
            let out = dst.appendingPathComponent(f)
            try? fm.copyItem(at: src, to: out)
        }
        diag("已从 \(legacy.path) 迁移 tsnet 状态（\(files.count) 项）")
    }

    /// MagicDNS 后缀，例如 `tailc12e.ts.net`（未登录时为空）
    private static func tailnetSuffix() -> String {
        guard let data = TsbridgeStatus().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["tailnet"] as? String else { return "" }
        return s
    }

    private static func selfIPs() -> [String] {
        guard let data = TsbridgeStatus().data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ips = obj["selfIPs"] as? [String] else { return [] }
        return ips
    }
}

/// `build-tsne.sh` 带 `-D TS_HAS_BRIDGE` 时由 `TSBridgeSetup` 调用。
func registerTailscaleRuntimeBridge() {
    NSLog("[TS] 链接 Tsbridge framework: %@", TsbridgeVersion())
    TailscaleRuntimeFactory.register { flow in TSBridgeRuntime(packetFlow: flow) }
}
