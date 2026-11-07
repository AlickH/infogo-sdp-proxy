import Foundation
import CryptoKit

enum SessionNum {
    /// 按客户端逻辑：path+query 原始值过滤字符后 md5
    static func compute(_ sessionStr: String) -> String {
        let allowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ=&()/.?_'\"<>")
        let filtered = sessionStr.filter { allowed.contains($0) }
        return md5Hex(filtered)
    }

    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
