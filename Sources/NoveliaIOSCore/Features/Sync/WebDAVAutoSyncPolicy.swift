import CryptoKit
import Foundation

// WebDAV 自动同步的触发判断。这里只做纯计算：何时值得同步、本机可同步状态是否在上次成功同步后变过。
// 生命周期监听与执行由 WebDAVSyncStore 负责。

/// 自动同步的触发来源。
enum WebDAVAutoSyncTrigger: String, Equatable {
    /// App 回到前台：拉取其他设备的改动。
    case foreground
    /// App 进入背景：把本机改动推送上去。
    case background
    /// 本机书库或标签变化后的延迟推送。
    case localChange
    /// 网络从断开恢复。
    case networkRestored
}

/// 一类同步数据的自动同步记录。书籍等清单内容与阅读时长分别记录：
/// 两者远端文件独立，阅读时长还要求服务器支持 ETag，一方失败不应拖累另一方的退避。
struct WebDAVAutoSyncPart: Codable, Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// 上次成功同步结束时本机状态的指纹；与当前指纹不同即有未推送的改动。
    var syncedFingerprint: String?
    /// 连续失败次数，用于退避；成功后清零，取消不计入。
    var failures = 0

    init(lastAttempt: Date? = nil, lastSuccess: Date? = nil, syncedFingerprint: String? = nil, failures: Int = 0) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.syncedFingerprint = syncedFingerprint
        self.failures = failures
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastAttempt = try container.decodeIfPresent(Date.self, forKey: .lastAttempt)
        lastSuccess = try container.decodeIfPresent(Date.self, forKey: .lastSuccess)
        syncedFingerprint = try container.decodeIfPresent(String.self, forKey: .syncedFingerprint)
        failures = try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0
    }
}

/// 自动同步的持久化记录（`webdav.autoSync.state.v1`）。手动同步成功也会更新，避免刚同步完又自动跑一次。
struct WebDAVAutoSyncState: Codable, Equatable {
    /// 清单内容：书籍、进度、系列、标签、背景与字体。
    var content = WebDAVAutoSyncPart()
    /// 阅读时长统计。
    var statistics = WebDAVAutoSyncPart()

    init(content: WebDAVAutoSyncPart = WebDAVAutoSyncPart(), statistics: WebDAVAutoSyncPart = WebDAVAutoSyncPart()) {
        self.content = content
        self.statistics = statistics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent(WebDAVAutoSyncPart.self, forKey: .content) ?? WebDAVAutoSyncPart()
        statistics = try container.decodeIfPresent(WebDAVAutoSyncPart.self, forKey: .statistics) ?? WebDAVAutoSyncPart()
    }
}

enum WebDAVAutoSyncPolicy {
    /// 回到前台时，距上次成功同步超过该间隔才拉取远端。
    static let staleInterval: TimeInterval = 10 * 60
    /// 两次自动同步之间至少间隔的时间，避免频繁切换前后台时连续请求有频率限制的服务器。
    static let minimumInterval: TimeInterval = 60
    /// 本机改动后等待合并的时间。
    static let localChangeDelay: TimeInterval = 60
    /// 第 n 次连续失败后的等待时间，超出部分沿用最后一项。
    static let retryDelays: [TimeInterval] = [60, 5 * 60, 15 * 60, 30 * 60]

    static func isDirty(_ part: WebDAVAutoSyncPart, fingerprint: String) -> Bool {
        part.syncedFingerprint != fingerprint
    }

    static func isBackingOff(_ part: WebDAVAutoSyncPart, now: Date) -> Bool {
        guard part.failures > 0, let lastAttempt = part.lastAttempt else { return false }
        let delay = retryDelays[min(part.failures, retryDelays.count) - 1]
        return now.timeIntervalSince(lastAttempt) < delay
    }

    /// 前台在有改动或远端可能已过期时同步；背景与本机改动只在有未推送的改动时同步；
    /// 失败后按退避等待，网络恢复时不等待退避，因为失败多半正是断网造成的。
    /// 任何触发都要距上次尝试至少 `minimumInterval`；被跳过的改动仍反映在指纹上，之后的触发会带上。
    static func shouldSync(_ trigger: WebDAVAutoSyncTrigger, part: WebDAVAutoSyncPart,
                           fingerprint: String, now: Date = Date()) -> Bool {
        if let lastAttempt = part.lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval { return false }
        let dirty = isDirty(part, fingerprint: fingerprint)
        switch trigger {
        case .foreground:
            guard !isBackingOff(part, now: now) else { return false }
            guard let lastSuccess = part.lastSuccess else { return true }
            return dirty || now.timeIntervalSince(lastSuccess) >= staleInterval
        case .background, .localChange:
            return dirty && !isBackingOff(part, now: now)
        case .networkRestored:
            return dirty || part.failures > 0
        }
    }

    /// 本机经常变化的清单内容的指纹：书籍记录、阅读位置、书库系列与屏蔽标签，按开启的同步项计算。
    /// 背景与字体需要读文件计算哈希，不纳入指纹；它们由回到前台的定期同步带上。
    @MainActor
    static func fingerprint(local: any WebDAVSyncLocalState,
                            web: any SyncBookLibrary<DownloadedWebNovel>,
                            wenku: any SyncBookLibrary<LocalWenkuEPUB>,
                            options: WebDAVSyncOptions) -> String {
        var hasher = Fingerprinter()
        hasher.add("options", [options.books, options.tags, options.backgrounds, options.fonts])
        if options.books {
            hasher.add("web", web.books)
            hasher.add("wenku", wenku.books)
            hasher.add("positions", local.readingPositions)
            hasher.add("series", local.librarySeries)
        }
        if options.tags { hasher.add("tags", local.blockedTags) }
        return hasher.finish()
    }

    /// 阅读时长快照的指纹。阅读中每次检查都会变化，因此只在前后台切换与网络恢复时比较。
    static func fingerprint(statistics: ReadingStatisticsSync) -> String {
        var hasher = Fingerprinter()
        hasher.add("statistics", statistics)
        return hasher.finish()
    }

    private struct Fingerprinter {
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return encoder
        }()
        private var hasher = SHA256()

        mutating func add<Value: Encodable>(_ label: String, _ value: Value) {
            hasher.update(data: Data(label.utf8))
            // 编码失败时写入固定标记，指纹仍然确定，最多多同步一次。
            hasher.update(data: (try? encoder.encode(value)) ?? Data("unencodable".utf8))
        }

        func finish() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
