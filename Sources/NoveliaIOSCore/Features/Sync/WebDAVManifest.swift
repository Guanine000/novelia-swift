import Foundation

// WebDAV 同步的远端清单（NoveliaSync/v1/index.json）及其书籍文件记录。
// 字段只增不改：新增字段须为可选，旧版应用解码时忽略。

struct WebDAVAsset: Codable, Equatable {
    let filename: String
    let hash: String
    /// 文件字节数，用于下载云端书籍前提示大小。可选：旧清单没有，旧版应用写回清单时也会丢掉。
    var size: Int64? = nil

    /// 只接受单级文件名，防止远端清单把文件写到书库目录之外。
    static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename == URL(fileURLWithPath: filename).lastPathComponent
            && filename != "." && filename != ".."
    }

    /// 远端 blob 以小写十六进制 SHA-256 命名。
    static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

struct WebDAVBook<Record: Codable>: Codable {
    let record: Record
    let assets: [WebDAVAsset]
}

extension WebDAVBook: Equatable where Record: Equatable {}

struct WebDAVManifest: Codable {
    var version = 1
    var webBooks: [WebDAVBook<DownloadedWebNovel>] = []
    var wenkuBooks: [WebDAVBook<LocalWenkuEPUB>] = []
    var positions: [String: SyncedReadingPosition] = [:]
    var blockedTags: [String: SyncedBlockedTag]? = nil
    var backgrounds: [String: SyncedReaderBackground]? = nil
    var fonts: [String: SyncedImportedFont]? = nil
    /// 书库系列与书籍归属；随书籍同步，旧版应用解码时忽略。
    var librarySeries: LibrarySeriesState? = nil
    /// 已从云端删除的书 `[书库键: 删除时间]`，见 `WebDAVDeletedBooks`。旧版应用不识别，可能再次上传这些书。
    var deletedBooks: [String: Date]? = nil
    /// 阅读器书签 `[书签 ID: 书签]`，含删除墓碑；随书籍同步。0.22.0 之前的版本不识别，写回清单时会丢弃。
    var bookmarks: [String: ReaderBookmark]? = nil
}

enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidURL
    case missingCredentials
    case unexpectedResponse(Int)
    case unsupportedManifest
    case invalidAsset
    case invalidStatistics
    case concurrentChange
    case missingBlob

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入 HTTPS WebDAV 文件夹地址。"
        case .missingCredentials: "请填写用户名和密码。"
        case .unexpectedResponse(401): "WebDAV 认证失败（HTTP 401）。坚果云请使用注册邮箱和单独生成的应用密码。"
        case .unexpectedResponse(403): "WebDAV 拒绝访问（HTTP 403）。请确认应用密码有效且目标文件夹可写。"
        case .unexpectedResponse(404): "WebDAV 路径不存在（HTTP 404）。请检查服务器地址是否包含 /dav/。"
        case .unexpectedResponse(409): "WebDAV 目录冲突（HTTP 409）。请检查填写的父文件夹是否已存在。"
        case .unexpectedResponse(429): "WebDAV 请求过于频繁（HTTP 429），请稍后再试。"
        case .unexpectedResponse(507): "WebDAV 空间不足（HTTP 507）。"
        case .unexpectedResponse(let status): "WebDAV 请求失败（HTTP \(status)）。"
        case .unsupportedManifest: "远端同步数据版本不受支持，未修改本地书籍。"
        case .invalidAsset: "远端书籍文件校验失败，未导入该文件。"
        case .invalidStatistics: "阅读统计数据格式无效或版本不受支持，未覆盖本机或云端统计。"
        case .concurrentChange: "另一台设备刚更新了同步数据，请重新同步。"
        case .missingBlob: "云端缺少这本书的文件。请在仍有这本书的设备上手动同步一次，会自动补传缺失的文件。"
        }
    }
}
