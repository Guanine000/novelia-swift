import Foundation

/// 方案二的本机观察记录，按服务器和账号隔离。缓存丢失、格式损坏或时钟倒退只会延后清理。
/// 这不是跨设备锁；24 小时观察与删除前复核仍不能消除最后一刻重新引用的窗口。
struct WebDAVBlobCleanupState: Codable {
    var version = 1
    var lastScan: Date?
    var lastUptime: TimeInterval?
    var unreferencedSince: [String: Date] = [:]
    var unreferencedUptimeSince: [String: TimeInterval] = [:]
    static let gracePeriod: TimeInterval = 24 * 60 * 60

    mutating func observe(_ unreferenced: Set<String>, at now: Date, uptime: TimeInterval) -> [String] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        if version != 1 || lastScan.map({ $0 > now || !$0.timeIntervalSinceReferenceDate.isFinite }) == true {
            self = Self()
        }
        if let lastScan {
            // 系统时钟跳变或重启后无法证明连续观察时长，重新等待；不因调快时间提前回收。
            if let lastUptime, uptime.isFinite, uptime >= lastUptime,
               abs(now.timeIntervalSince(lastScan) - (uptime - lastUptime)) <= 300 {
                // 同一连续计时区间，继续观察。
            } else { self = Self() }
        }
        let previousScan = lastScan
        unreferencedSince = unreferencedSince.filter {
            unreferenced.contains($0.key) && WebDAVAsset.isValidHash($0.key)
                && $0.value.timeIntervalSinceReferenceDate.isFinite && $0.value <= now
        }
        unreferencedUptimeSince = unreferencedUptimeSince.filter { unreferencedSince[$0.key] != nil && $0.value.isFinite && $0.value <= uptime }
        let ready = unreferencedSince.filter { hash, first in
            previousScan.map { first <= $0 && $0 < now } == true && now.timeIntervalSince(first) >= Self.gracePeriod
                && unreferencedUptimeSince[hash].map { uptime - $0 >= Self.gracePeriod } == true
        }.map(\.key).sorted()
        for hash in unreferenced where unreferencedSince[hash] == nil || unreferencedUptimeSince[hash] == nil {
            unreferencedSince[hash] = now
            unreferencedUptimeSince[hash] = uptime
        }
        lastScan = now
        lastUptime = uptime
        return ready
    }
}

struct WebDAVBlobCleanupResult {
    var deleted = 0
    var pending = 0
    var repaired = 0
    var missingHashes: Set<String> = []
    var warning: String?

    var summary: String {
        var text = deleted > 0 ? "已清理 \(deleted) 个云端闲置文件。" : ""
        if pending > 0 { text += "\(pending) 个闲置文件等待后续核对与清理。" }
        if repaired > 0 { text += "已补回 \(repaired) 个被重新引用的文件。" }
        if !missingHashes.isEmpty { text += "清理后发现 \(missingHashes.count) 个重新引用的文件缺失，请在仍有副本的设备上手动同步补传。" }
        if let warning { text += "云端清理已暂缓：\(warning)" }
        return text
    }
}

/// 只在成功的手动内容同步后、同一本机清单串行门内运行。先稳定扫描，再逐文件复核最新清单；
/// 每次最多清理十个，以限制 WebDAV 请求数。失败只暂缓维护，不把已成功的内容同步记成失败。
@MainActor
enum WebDAVBlobCleaner {
    static let batchLimit = 10

    static func clean(remote: any WebDAVRemote, defaults: UserDefaults, server: String, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                      repairFiles: (Set<String>) async throws -> [String: URL]) async -> WebDAVBlobCleanupResult {
        let key = SettingsKey.WebDAV.blobCleanup + "." + FileContentHash.sha256(Data(server.utf8))
        var state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WebDAVBlobCleanupState.self, from: $0) }
            ?? WebDAVBlobCleanupState()
        var result = WebDAVBlobCleanupResult()
        var attempted: Set<String> = []
        do {
            try Task.checkCancellation()
            let (manifest, etag) = try await snapshot(remote)
            guard let present = try await remote.listBlobs() else {
                throw WebDAVSyncError.unsupportedConditions
            }
            let (_, checkedVersion) = try await snapshot(remote)
            guard etag == checkedVersion else { throw WebDAVSyncError.concurrentChange }
            let unused = present.filter(WebDAVAsset.isValidHash).subtracting(WebDAVSyncPlanner.referencedBlobs(in: manifest))
            let ready = state.observe(unused, at: now, uptime: uptime)
            for hash in ready.prefix(batchLimit) {
                try Task.checkCancellation()
                let (latest, latestVersion) = try await snapshot(remote)
                let references = WebDAVSyncPlanner.referencedBlobs(in: latest)
                if references.contains(hash) { state.unreferencedSince[hash] = nil }
                // 任意清单改动都会推迟本批清理，不沿用早先的引用快照。
                guard latestVersion == etag else { throw WebDAVSyncError.concurrentChange }
                guard !references.contains(hash) else { continue }
                attempted.insert(hash) // DELETE 响应丢失也可能已执行，之后仍需核对这些文件。
                try await remote.deleteBlob(hash)
                result.deleted += 1
                state.unreferencedSince[hash] = nil
            }
        } catch {
            state = WebDAVBlobCleanupState()
            result.warning = error is CancellationError ? "已取消，未完成的文件留待后续同步。" : error.localizedDescription
        }

        // 复核只针对本批可能删除的文件；不根据可能不完整的目录列表认定正文缺失。
        if !attempted.isEmpty && !Task.isCancelled {
            do {
                let (latest, _) = try await snapshot(remote)
                let reused = attempted.intersection(WebDAVSyncPlanner.referencedBlobs(in: latest))
                var missing: Set<String> = []
                for hash in reused.sorted() {
                    try Task.checkCancellation()
                    do {
                        let file = try await remote.downloadBlob(hash)
                        try? FileManager.default.removeItem(at: file)
                    } catch WebDAVSyncError.missingBlob { missing.insert(hash) }
                }
                if !missing.isEmpty {
                    // 上传前再次验证本机内容，不能把错误副本写到相同哈希的路径。
                    result.missingHashes = missing
                    let files = try await repairFiles(missing)
                    for hash in missing.sorted() {
                        try Task.checkCancellation()
                        guard let file = files[hash] else { result.missingHashes.insert(hash); continue }
                        let actual = try await Task.detached(priority: .utility) { try FileContentHash.sha256(file) }.value
                        guard actual == hash else { result.missingHashes.insert(hash); continue }
                        try await remote.uploadBlob(file, hash: hash)
                        let verified = try await remote.downloadBlob(hash)
                        try? FileManager.default.removeItem(at: verified)
                        result.repaired += 1
                        result.missingHashes.remove(hash)
                    }
                }
            } catch {
                result.warning = "清理后的完整性核对尚未完成，请稍后手动同步。"
            }
        } else if !attempted.isEmpty {
            result.warning = "清理后的完整性核对尚未完成，请稍后手动同步。"
        }
        result.pending = state.unreferencedSince.count
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
        return result
    }

    private static func snapshot(_ remote: any WebDAVRemote) async throws -> (WebDAVManifest, String) {
        let (manifest, version, existed) = try await remote.fetchManifest()
        guard existed, manifest.version == 1, let version, WebDAVClient.strongETag(version) != nil else {
            throw WebDAVSyncError.unsupportedConditions
        }
        guard WebDAVSyncPlanner.referencedBlobs(in: manifest).allSatisfy(WebDAVAsset.isValidHash) else {
            throw WebDAVSyncError.invalidAsset
        }
        return (manifest, version)
    }

    /// 只有清理后确实出现重新引用且文件缺失时才查找副本；哈希计算在后台执行，不依赖旧缓存。
    static func localRepairFiles(_ hashes: Set<String>, local: any WebDAVSyncLocalState,
                                 web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>,
                                 cloud: any SyncCloudCatalog) async throws -> [String: URL] {
        var candidates = Set<URL>()
        for book in web.books { candidates.formUnion(web.syncFiles(for: book).values) }
        for book in wenku.books { candidates.formUnion(wenku.syncFiles(for: book).values) }
        candidates.formUnion(try local.fontFiles().values)
        for dark in [false, true] {
            for landscape in [false, true] { candidates.insert(local.backgroundImageURL(dark: dark, landscape: landscape)) }
        }
        for hash in hashes { if let cover = cloud.cachedCover(hash: hash) { candidates.insert(cover) } }
        let urls = Array(candidates)
        return try await Task.detached(priority: .utility) {
            var files: [String: URL] = [:]
            for url in urls {
                try Task.checkCancellation()
                guard let hash = try? FileContentHash.sha256(url), hashes.contains(hash) else { continue }
                files[hash] = url
                if files.count == hashes.count { break }
            }
            return files
        }.value
    }
}
