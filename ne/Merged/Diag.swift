import Foundation

/// 扩展侧的诊断日志：直接追加到 /tmp/sdpne.log（宿主用户可读）。
///
/// 合并后三路流量走同一条 flow，出问题时 unified log 里几乎看不到 NSLog
/// （SDPNE 以 root 运行的 sysext，多数条目被私有化），所以留一个落盘通道。
/// 只做计数采样，不会把每个包都写进来。
enum Diag {
    private static let path = "/tmp/sdpne.log"
    private static let lock = NSLock()

    static func log(_ tag: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [\(tag)] \(message)\n"
        let fm = FileManager.default
        if let n = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, n > 4 * 1024 * 1024 {
            try? fm.removeItem(atPath: path)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
