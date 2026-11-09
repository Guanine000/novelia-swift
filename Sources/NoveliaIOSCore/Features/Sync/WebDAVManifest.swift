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
    /// 仅独立 characters-v1 目录使用，旧客户端不会读取或覆盖该目录。
    var characters: CharacterSyncState? = nil
    var webEPUBMaps: [String: WebNovelEPUBMap]? = nil
    var version = 1
    var webBooks: [WebDAVBook<DownloadedWebNovel>] = []
    var wenkuBooks: [WebDAVBook<LocalWenkuEPUB>] = []
    var positions: [String: SyncedReadingPosition] = [:]
    var blockedTags: [String: SyncedBlockedTag]? = nil
    var backgrounds: [String: SyncedReaderBackground]? = nil
    var fonts: [String: SyncedImportedFont]? = nil
    /// 书库系列与书籍归属；随书籍同步，旧版应用解码时忽略。
    var librarySeries: LibrarySeriesState? = nil
    /// 最近三十天从云端删除的书 `[书库键: 删除时间]`，见 `WebDAVDeletedBooks`。过期后旧设备可能再次上传这些书。
    var deletedBooks: [String: Date]? = nil
    /// 阅读器书签 `[书签 ID: 书签]`，含删除墓碑；随书籍同步。0.22.0 之前的版本不识别，写回清单时会丢弃。
    var bookmarks: [String: ReaderBookmark]? = nil
}

enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidURL
    case missingCredentials
    case unexpectedResponse(Int)
    case unsupportedConditions
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
        case .unsupportedConditions: "此 WebDAV 服务未提供可靠的文件版本或条件请求，已停止内容同步以保护现有数据。"
        case .unsupportedManifest: "远端同步数据版本不受支持，未修改本地书籍。"
        case .invalidAsset: "远端书籍文件校验失败，未导入该文件。"
        case .invalidStatistics: "阅读统计数据格式无效或版本不受支持，未覆盖本机或云端统计。"
        case .concurrentChange: "同步数据的版本发生变化，请稍后重试。"
        case .missingBlob: "云端缺少这本书的文件。请在仍有这本书的设备上手动同步一次，会自动补传缺失的文件。"
        }
    }
}

/// 人物同步按事实ID合并，移动/合并/拆分改变归属，删除保留墓碑；不上传扫描缓存或AI配置。
struct CharacterSyncFact: Codable, Equatable {
    let entity: String
    let work: String
    let fact: CharacterFact
}
struct CharacterPortrait: Codable, Equatable {
    let hash: String
    let book: String
    let identity: String
    /// 添加图片时的阅读边界；回退到更早位置时隐藏，避免用户图片泄露后续形象。
    let boundary: Int
}
struct CharacterSyncValue<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value?
    var updatedAt: Date
}
struct CharacterSyncState: Codable, Equatable {
    var version = 1
    var facts: [String: CharacterSyncValue<CharacterSyncFact>] = [:]
    var orders: [String: CharacterSyncValue<[String]>] = [:]
    var portraits: [String: CharacterSyncValue<CharacterPortrait>] = [:]
    var rejected: Set<String> = []
    var scans: [String: CharacterSyncValue<CharacterScanCheckpoint>] = [:]
    private enum CodingKeys: String, CodingKey { case version, facts, orders, portraits, rejected, scans }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        facts = try values.decodeIfPresent([String: CharacterSyncValue<CharacterSyncFact>].self, forKey: .facts) ?? [:]
        orders = try values.decodeIfPresent([String: CharacterSyncValue<[String]>].self, forKey: .orders) ?? [:]
        portraits = try values.decodeIfPresent([String: CharacterSyncValue<CharacterPortrait>].self, forKey: .portraits) ?? [:]
        rejected = try values.decodeIfPresent(Set<String>.self, forKey: .rejected) ?? []
        scans = try values.decodeIfPresent([String: CharacterSyncValue<CharacterScanCheckpoint>].self, forKey: .scans) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(facts, forKey: .facts); try values.encode(orders, forKey: .orders)
        try values.encode(portraits, forKey: .portraits); try values.encode(rejected.sorted(), forKey: .rejected)
        try values.encode(scans, forKey: .scans)
    }
    func validated() throws -> Self {
        guard version == 1, facts.count <= 40_000, orders.count <= 2_000, portraits.count <= 2_000, scans.count <= 10_000, rejected.count <= 20_000,
              rejected.allSatisfy(WebDAVAsset.isValidHash) else { throw WebDAVSyncError.invalidAsset }
        for (id, record) in facts {
            guard !id.isEmpty, id.utf8.count <= 128, record.updatedAt.timeIntervalSince1970.isFinite else { throw WebDAVSyncError.invalidAsset }
            if let value = record.value {
                guard value.fact.id == id, !value.entity.isEmpty, value.entity.utf8.count <= 128,
                      !value.work.isEmpty, value.work.utf8.count <= 128, value.fact.book.utf8.count <= 2_048,
                      value.fact.identity.utf8.count <= 2_048, CharacterLexiconStore.valid(value.fact) else { throw WebDAVSyncError.invalidAsset }
            }
        }
        for (work, record) in orders {
            guard !work.isEmpty, work.utf8.count <= 128, record.updatedAt.timeIntervalSince1970.isFinite else { throw WebDAVSyncError.invalidAsset }
            if let order = record.value {
                guard order.count <= 2_000, Set(order).count == order.count,
                      order.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else { throw WebDAVSyncError.invalidAsset }
            }
        }
        for (id, record) in portraits {
            guard !id.isEmpty, id.utf8.count <= 128, record.updatedAt.timeIntervalSince1970.isFinite else { throw WebDAVSyncError.invalidAsset }
            if let value = record.value {
                guard WebDAVAsset.isValidHash(value.hash), value.boundary >= 0, !value.book.isEmpty,
                      value.book.utf8.count <= 2_048, value.identity.utf8.count <= 2_048 else { throw WebDAVSyncError.invalidAsset }
            }
        }
        for (key, record) in scans {
            guard WebDAVAsset.isValidHash(key), record.updatedAt.timeIntervalSince1970.isFinite else { throw WebDAVSyncError.invalidAsset }
            if let scan = record.value {
                guard !scan.signature.isEmpty, scan.signature.utf8.count <= 128, (0...1_000_000).contains(scan.nextChapter) else { throw WebDAVSyncError.invalidAsset }
            }
        }
        guard try JSONEncoder().encode(self).count <= 8 * 1_024 * 1_024 else { throw WebDAVSyncError.invalidAsset }
        return self
    }
    static func merged(_ a: Self, _ b: Self) throws -> Self {
        _ = try a.validated(); _ = try b.validated()
        var value = a
        value.facts = merge(a.facts, b.facts); value.orders = merge(a.orders, b.orders)
        value.portraits = merge(a.portraits, b.portraits); value.rejected.formUnion(b.rejected)
        value.scans = merge(a.scans, b.scans)
        for key in Set(a.scans.keys).intersection(b.scans.keys) {
            if let left = a.scans[key], let right = b.scans[key], let x = left.value, let y = right.value, x.signature == y.signature {
                value.scans[key] = .init(value: x.nextChapter >= y.nextChapter ? x : y, updatedAt: max(left.updatedAt, right.updatedAt))
            }
        }
        return try value.validated()
    }
    private static func merge<T>(_ a: [String: CharacterSyncValue<T>], _ b: [String: CharacterSyncValue<T>]) -> [String: CharacterSyncValue<T>] {
        var result = a
        for (key, incoming) in b {
            guard let current = result[key] else { result[key] = incoming; continue }
            if incoming.updatedAt > current.updatedAt { result[key] = incoming }
            else if incoming.updatedAt == current.updatedAt {
                // 同时写入确定性决胜，删除优先，避免不同设备反复翻转。
                if incoming.value == nil { result[key] = incoming }
                else if current.value != nil {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let lhs = (try? encoder.encode(current)) ?? Data(), rhs = (try? encoder.encode(incoming)) ?? Data()
                    if lhs.lexicographicallyPrecedes(rhs) { result[key] = incoming }
                }
            }
        }
        return result
    }
    var portraitHashes: Set<String> { Set(portraits.values.compactMap { $0.value?.hash }) }
}
