import Foundation
import os

/// 扩展侧的诊断日志。
///
/// 合并后三路流量走同一条 flow，出问题时 unified log 里几乎看不到 NSLog
/// （NE 会把扩展进程的输出私有化），所以留一个落盘通道。
/// 只做计数采样，不会把每个包都写进来。
///
/// 载体换成 .appex 后扩展是**沙箱进程**，`/tmp` 不再可写，必须落到 App Group
/// 容器里：这是沙箱进程与宿主 App 都能访问的固定位置。
/// 路径：~/Library/Group Containers/<app-group>/sdpne.log
enum Diag {
    private static let lock = NSLock()

    /// App Group 容器内的日志文件；容器不可用时退回统一日志。
    static var path: String? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "KLU8GF65GP.com.alick.sdp-proxy")
        else { return nil }
        return base.appendingPathComponent("sdpne.log").path
    }

    static func log(_ tag: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(tag)] \(message)\n"
        lock.lock(); defer { lock.unlock() }

        // 统一日志始终写一份：落盘失败时这是唯一可查的证据。
        os_log("%{public}@", log: OSLog(subsystem: "com.alick.sdp-proxy.tunnel", category: tag),
               type: .default, message)

        guard let path else { return }
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
