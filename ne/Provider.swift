import Foundation
import NetworkExtension
import Network

/// 透明代理系统扩展：把本机所有 TCP 连接转发到 App 内置的 SOCKS5 代理
final class Provider: NETransparentProxyProvider {
    private var socksHost = "127.0.0.1"
    private var socksPort: UInt16 = 11095
    private var active: [ObjectIdentifier: Conversation] = [:]
    private let lock = NSLock()

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        if let cfg = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
            if let h = cfg["socksHost"] as? String { socksHost = h }
            if let p = cfg["socksPort"] as? Int, let pp = UInt16(exactly: p) { socksPort = pp }
        }
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetwork: nil, remotePrefix: 0,
                          localNetwork: nil, localPrefix: 0,
                          protocol: .TCP, direction: .outbound)
        ]
        // 排除回环，避免本地 SOCKS/HTTP 代理被透明代理再次捕获
        let loopbackV4 = NENetworkRule(remoteNetwork: NWHostEndpoint(hostname: "127.0.0.1", port: "0"),
                                       remotePrefix: 8, localNetwork: nil, localPrefix: 0,
                                       protocol: .any, direction: .outbound)
        settings.excludedNetworkRules = [loopbackV4]
        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock()
        let all = Array(active.values)
        active.removeAll()
        lock.unlock()
        for c in all { c.cancel() }
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcp = flow as? NEAppProxyTCPFlow else { return false }
        let conv = Conversation(provider: self, flow: tcp, socksHost: socksHost, socksPort: socksPort)
        lock.lock()
        active[ObjectIdentifier(conv)] = conv
        lock.unlock()
        conv.start()
        return true
    }

    func finished(_ conv: Conversation) {
        lock.lock()
        active.removeValue(forKey: ObjectIdentifier(conv))
        lock.unlock()
    }
}

/// 单条 TCP 流 <-> SOCKS5 转发
final class Conversation {
    private weak var provider: Provider?
    private let flow: NEAppProxyTCPFlow
    private let socksHost: String
    private let socksPort: UInt16
    private var socket: NWConnection?
    private let queue = DispatchQueue(label: "sdp.ne.conv")
    private var closed = false

    init(provider: Provider, flow: NEAppProxyTCPFlow, socksHost: String, socksPort: UInt16) {
        self.provider = provider
        self.flow = flow
        self.socksHost = socksHost
        self.socksPort = socksPort
    }

    func start() {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.close(error: error)
                return
            }
            self.queue.async { self.connect() }
        }
    }

    func cancel() {
        closed = true
        socket?.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    private func close(error: Error?) {
        guard !closed else { return }
        closed = true
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        socket?.cancel()
        provider?.finished(self)
    }

    // MARK: - SOCKS5

    private func connect() {
        guard let port = NWEndpoint.Port(rawValue: socksPort) else { close(error: nil); return }
        let conn = NWConnection(host: NWEndpoint.Host(socksHost), port: port, using: .tcp)
        socket = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.queue.async { self.handshake() }
            case .failed(let e):
                self.close(error: e)
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func handshake() {
        guard let host = remoteHost(), let port = remotePort(), !host.isEmpty else {
            close(error: nil); return
        }
        guard let sock = socket else { close(error: nil); return }
        sock.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { [weak self] err in
            guard let self = self else { return }
            if err != nil { self.close(error: err); return }
            self.recv(sock, 2) { hello in
                guard let hello = hello, hello.count == 2, hello[0] == 0x05 else { self.close(error: nil); return }
                let hostBytes = Array(host.utf8)
                var req = Data([0x05, 0x01, 0x00, 0x03, UInt8(min(hostBytes.count, 255))])
                req.append(contentsOf: hostBytes.prefix(255))
                req.append(UInt8(port >> 8))
                req.append(UInt8(port & 0xFF))
                sock.send(content: req, completion: .contentProcessed { [weak self] err in
                    guard let self = self else { return }
                    if err != nil { self.close(error: err); return }
                    self.recv(sock, 4) { rep in
                        guard let rep = rep, rep.count == 4, rep[1] == 0 else {
                            self.close(error: nil); return
                        }
                        self.consumeBound(sock, atyp: rep[3]) {
                            self.relay()
                        }
                    }
                })
            }
        })
    }

    private func consumeBound(_ sock: NWConnection, atyp: UInt8, done: @escaping () -> Void) {
        switch atyp {
        case 0x01:
            recv(sock, 4) { _ in self.recv(sock, 2) { _ in done() } }
        case 0x03:
            recv(sock, 1) { len in
                let n = Int(len?.first ?? 0)
                self.recv(sock, n) { _ in self.recv(sock, 2) { _ in done() } }
            }
        case 0x04:
            recv(sock, 16) { _ in self.recv(sock, 2) { _ in done() } }
        default:
            done()
        }
    }

    private func recv(_ sock: NWConnection, _ n: Int, _ done: @escaping (Data?) -> Void) {
        guard n > 0 else { done(Data()); return }
        sock.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
            if err != nil { done(nil); return }
            done(data ?? Data())
        }
    }

    private func relay() {
        // App → 远端
        readLoop()
        // 远端 → App
        writeLoop()
    }

    private func readLoop() {
        flow.readData { [weak self] data, error in
            guard let self = self else { return }
            if let error = error { self.close(error: error); return }
            guard let data = data, !data.isEmpty else {
                self.flow.closeReadWithError(nil)
                return
            }
            self.socket?.send(content: data, completion: .contentProcessed { err in
                if err != nil { self.close(error: err); return }
                self.readLoop()
            })
        }
    }

    private func writeLoop() {
        socket?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error { self.close(error: error); return }
            if let data = data, !data.isEmpty {
                self.flow.write(data) { err in
                    if let err = err { self.close(error: err); return }
                    if isComplete { self.close(error: nil) } else { self.writeLoop() }
                }
            } else if isComplete {
                self.close(error: nil)
            } else {
                self.writeLoop()
            }
        }
    }

    // MARK: - flow 元数据

    private func endpointHostPort() -> (String, UInt16)? {
        if #available(macOS 15.0, *) {
            if case let .hostPort(host, port) = flow.remoteFlowEndpoint {
                return ("\(host)", port.rawValue)
            }
        }
        if let ep = flow.remoteEndpoint as? NWHostEndpoint {
            return (ep.hostname, UInt16(ep.port) ?? 0)
        }
        return nil
    }

    private func remoteHost() -> String? { endpointHostPort()?.0 }
    private func remotePort() -> UInt16? { endpointHostPort()?.1 }
}
