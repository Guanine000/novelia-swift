import Foundation
import CryptoKit

enum FileContentHash {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 哈希缓存的键：路径、大小与修改时间，任一变化都重新计算。读取失败时返回 nil，不使用缓存。
    /// 直接读取文件属性；`URL.resourceValues` 会在同一个 URL 实例上缓存旧值。
    static func identity(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(url.path)|\(size.int64Value)|\(modified.timeIntervalSince1970)"
    }
}
