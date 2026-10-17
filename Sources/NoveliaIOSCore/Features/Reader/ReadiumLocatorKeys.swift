import Foundation

/// Readium 阅读器在本机偏好中保存的精确位置（Locator）与保存时间的键名，阅读器与书库清理共用这一处定义。
/// EPUB 按文件内容哈希；TXT 按 `txt|<文件哈希>|<分章规则指纹>` 身份。键名是本机数据的兼容契约，不可随意修改。
public enum ReadiumLocatorKeys {
    static let bookLocatorPrefix = "readium.locator.v1."
    static let bookTimePrefix = "readium.locatorTime.v1."
    static let textLocatorPrefix = "readium.text.locator.v1."
    static let textTimePrefix = "readium.text.time.v1."

    public static func bookLocator(hash: String) -> String { bookLocatorPrefix + hash }
    public static func bookTime(hash: String) -> String { bookTimePrefix + hash }
    public static func textLocator(identity: String) -> String { textLocatorPrefix + identity }
    public static func textTime(identity: String) -> String { textTimePrefix + identity }

    /// 文件哈希已不属于任何书籍（本机与云端都没有）的 Readium 精确位置键。
    /// 精确位置只用于本机快速恢复，书不在书库时没有用处；共享阅读位置另按时间清理。
    static func orphanedKeys(_ keys: some Sequence<String>, keepingHashes: Set<String>) -> [String] {
        keys.filter { key in
            if let prefix = [bookLocatorPrefix, bookTimePrefix].first(where: key.hasPrefix) {
                return !keepingHashes.contains(String(key.dropFirst(prefix.count)))
            }
            if let prefix = [textLocatorPrefix, textTimePrefix].first(where: key.hasPrefix) {
                let parts = key.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "txt" else { return false }
                return !keepingHashes.contains(String(parts[1]))
            }
            return false
        }
    }
}
