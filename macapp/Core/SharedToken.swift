import Foundation

/// App 与系统扩展共享的令牌文件
/// 扩展以 root 运行，App Group 容器路径与用户进程不同，
/// 因此使用双方都可访问的固定路径。
enum SharedToken {
    static let dir = URL(fileURLWithPath: "/Users/Shared/SDPProxy", isDirectory: true)
    static let fileURL = dir.appendingPathComponent("token.txt")

    static func write(_ token: String?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = (token ?? "").data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}
