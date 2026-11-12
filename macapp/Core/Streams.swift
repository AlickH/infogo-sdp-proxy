import Foundation
import Network

/// 一次性闩：保证 continuation 只被 resume 一次。
/// 供 `NWConnection` 的 @Sendable 回调（stateUpdateHandler / asyncAfter）共享，
/// 避免在并发上下文中捕获非 Sendable 的可变局部状态。
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        // 锁外 resume，避免持锁回调到 continuation 的恢复逻辑
        body()
    }
}

protocol ByteStream: AnyObject {
    func send(_ data: Data) async throws
    func receive(max: Int) async throws -> Data?
    func cancel()
}

extension ByteStream {
    func closeWrite() async {}
    func receive() async throws -> Data? { try await receive(max: 65536) }
}

/// 直连 TCP 流
final class SocketStream: ByteStream {
    let conn: NWConnection
    init(conn: NWConnection) { self.conn = conn }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    func closeWrite() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                      completion: .contentProcessed { _ in cont.resume() })
        }
    }

    func receive(max: Int = 65536) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, err in
                if let err = err {
                    // ENOMSG(96)：对端写端已关闭，按 EOF 处理
                    if (err as NSError).code == 96 { cont.resume(returning: nil) }
                    else { cont.resume(throwing: err) }
                    return
                }
                if let data = data, !data.isEmpty { cont.resume(returning: data); return }
                cont.resume(returning: nil)
            }
        }
    }

    func cancel() { conn.cancel() }
}

extension Tunnel: ByteStream {}

/// 建立直连（用公共 DNS 解析，避开 fake-IP）
func dialDirect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> ByteStream {
    let ip = PublicDNS.resolveIPv4(host) ?? (PublicDNS.isIPv4(host) ? host : nil)
    guard let target = ip else { throw GatewayError.connect("域名解析失败: \(host)") }
    let conn = NWConnection(host: NWEndpoint.Host(target),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: .tcp)
    try await waitForReady(conn, timeout: timeout)
    return SocketStream(conn: conn)
}

func waitForReady(_ conn: NWConnection, timeout: TimeInterval) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let once = ResumeOnce()
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: once.run { cont.resume() }
            case .failed(let e): once.run { cont.resume(throwing: GatewayError.connect(e.localizedDescription)) }
            case .cancelled: once.run { cont.resume(throwing: GatewayError.connect("已取消")) }
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            once.run { cont.resume(throwing: GatewayError.connect("超时")) }
        }
    }
}

/// 双向转发
func relay(_ a: ByteStream, _ b: ByteStream) async {
    // ByteStream 是未标 Sendable 的引用类型（NWConnection 封装）。两个方向各持一端、
    // 互不共享可变状态，故显式标注 unsafe 允许跨 Task 传递（行为不变）。
    nonisolated(unsafe) let sa = a
    nonisolated(unsafe) let sb = b
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await pipe(sa, sb) }
        group.addTask { await pipe(sb, sa) }
        await group.waitForAll()
    }
    // 给对端一点时间把已发送的数据排空，避免 cancel 丢弃尾部数据
    try? await Task.sleep(nanoseconds: 400_000_000)
    a.cancel(); b.cancel()
}

private func pipe(_ from: ByteStream, _ to: ByteStream) async {
    do {
        while true {
            guard let chunk = try await from.receive() else { break }
            try await to.send(chunk)
        }
    } catch {
        // 任一方向出错则结束
    }
}

/// 从字节流读取恰好 n 字节
func readExactly(_ s: ByteStream, _ n: Int) async throws -> Data {
    var out = Data()
    while out.count < n {
        guard let chunk = try await s.receive(max: n - out.count) else { throw GatewayError.closed }
        out.append(chunk)
    }
    return out
}

/// 读到 CRLFCRLF（HTTP 头）
func readHTTPHeaders(_ s: ByteStream, limit: Int = 65536) async throws -> Data {
    var buf = Data()
    while buf.count < limit {
        guard let chunk = try await s.receive(max: 4096) else { break }
        buf.append(chunk)
        if buf.range(of: Data([0x0D,0x0A,0x0D,0x0A])) != nil { break }
    }
    return buf
}
