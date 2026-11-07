import Foundation
import Security

enum RSA {
    /// PEM 公钥 → PKCS#1 DER（SecKey 需要）
    static func encryptPKCS1(plain: Data, pemPublicKey: String) -> Data? {
        guard let der = derFromPEM(pemPublicKey) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            print("SecKeyCreateWithData 失败: \(String(describing: err))")
            return nil
        }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, &err) else {
            print("加密失败: \(String(describing: err))")
            return nil
        }
        return cipher as Data
    }

    /// PEM → DER，并将 SPKI 转成 PKCS#1
    static func derFromPEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        guard let b64 = Data(base64Encoded: lines.joined()) else { return nil }
        return spkiToPKCS1(b64) ?? b64
    }

    /// SPKI: SEQUENCE { SEQUENCE {...}, BIT STRING { unusedBits, RSAPublicKey } }
    static func spkiToPKCS1(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        var i = 0

        func readLen() -> Int? {
            guard i < bytes.count else { return nil }
            var len = Int(bytes[i]); i += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard i + n <= bytes.count else { return nil }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[i]); i += 1 }
            }
            return len
        }

        guard bytes.count > 2, bytes[i] == 0x30 else { return nil }
        i += 1
        _ = readLen()
        // algorithm SEQUENCE
        guard i < bytes.count, bytes[i] == 0x30 else { return nil }
        i += 1
        guard let algLen = readLen() else { return nil }
        i += algLen
        // BIT STRING
        guard i < bytes.count, bytes[i] == 0x03 else { return nil }
        i += 1
        guard let bitLen = readLen() else { return nil }
        guard i + bitLen <= bytes.count, bitLen > 1 else { return nil }
        let unused = Int(bytes[i])
        guard unused == 0 else { return nil }
        let start = i + 1
        return Data(bytes[start..<(i + bitLen)])
    }
}
