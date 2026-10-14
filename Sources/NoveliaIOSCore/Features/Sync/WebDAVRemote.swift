import Foundation

// WebDAV 远端访问：同步流程只依赖 `WebDAVRemote`，`WebDAVClient` 为 HTTP 实现。
// 远端布局：<地址>/NoveliaSync/v1/index.json 为清单，blobs/<sha256> 为书籍与资源文件，
// statistics/<设备 ID>.json 为各设备阅读统计。

protocol WebDAVRemote {
    /// 确认用户填写的文件夹存在且可访问。
    func verifyConnection() async throws
    /// 依次创建 NoveliaSync/、v1/ 与 blobs/，已存在的跳过。
    func prepareFolders() async throws
    /// 返回清单、ETag，以及远端是否已有清单；没有清单时返回空清单。
    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool)
    /// 条件写入清单：有 ETag 用 If-Match，首次写入用 If-None-Match；冲突时抛出 `concurrentChange`。
    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws
    /// 上传以内容哈希命名的文件；远端已有时跳过。
    func uploadBlob(_ file: URL, hash: String) async throws
    /// 下载并校验哈希，返回调用方负责删除的临时文件。
    func downloadBlob(_ hash: String) async throws -> URL
    /// 删除不再被清单引用的 blob；不存在也视为成功。
    func deleteBlob(_ hash: String) async throws
}

// Compatibility name for existing sync tests and callers.
typealias WebDAVFileHash = FileContentHash


/// 只允许重定向到同一主机与端口的 HTTPS 地址，避免把 Basic 认证头带到其他服务器。
final class WebDAVRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              destination.scheme?.lowercased() == "https",
              destination.host == original.host,
              (destination.port ?? 443) == (original.port ?? 443) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// 记录已确认存在的同步目录，自动同步时跳过连接检查与逐级 PROPFIND，以减少对有请求频率限制的服务器的访问。
/// 按服务器地址与用户名区分；任何同步失败都应调用 `clear()`，下次重新完整检查。
struct WebDAVFolderCache {
    let defaults: UserDefaults

    func isPrepared(_ key: String) -> Bool { prepared.contains(key) }

    func markPrepared(_ key: String) {
        guard !prepared.contains(key) else { return }
        defaults.set(Array(prepared.union([key])).sorted(), forKey: SettingsKey.WebDAV.preparedFolders)
    }

    func clear() { defaults.removeObject(forKey: SettingsKey.WebDAV.preparedFolders) }

    private var prepared: Set<String> {
        Set(defaults.stringArray(forKey: SettingsKey.WebDAV.preparedFolders) ?? [])
    }
}

/// 每次同步新建一个客户端；释放时让会话失效，否则带 delegate 的 URLSession 会一直被系统持有。
final class WebDAVClient: WebDAVRemote, ReadingStatisticsRemote {
    let base: URL
    let root: URL
    let authorization: String
    /// 仅供测试检查会话的生命周期。
    let session: URLSession
    /// 为 nil 时每次都完整检查目录（手动同步与测试）。
    private let folderCache: WebDAVFolderCache?
    private let folderCacheKey: String

    /// `configuration` 仅供测试注入 URLProtocol；应用使用默认的临时会话。
    init(address: String, username: String, password: String,
         configuration: URLSessionConfiguration = .ephemeral, folderCache: WebDAVFolderCache? = nil) throws {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw WebDAVSyncError.invalidURL }
        base = url
        root = url.appendingPathComponent("NoveliaSync", isDirectory: true)
                  .appendingPathComponent("v1", isDirectory: true)
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        session = URLSession(configuration: configuration, delegate: WebDAVRedirectGuard(), delegateQueue: nil)
        self.folderCache = folderCache
        folderCacheKey = Self.serverKey(username: username, base: url)
    }

    /// 缓存用的服务器标识。
    static func serverKey(username: String, base: URL) -> String { "\(username)@\(base.absoluteString)" }
    var serverKey: String { folderCacheKey }

    deinit {
        session.finishTasksAndInvalidate()
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func status(_ response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else { throw WebDAVSyncError.unexpectedResponse(0) }
        return response.statusCode
    }

    private func read(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .networkConnectionLost {
            return try await session.data(for: request)
        }
    }

    func verifyConnection() async throws {
        if folderCache?.isPrepared(folderCacheKey) == true { return }
        guard try await exists(base) else { throw WebDAVSyncError.unexpectedResponse(404) }
    }

    private func exists(_ url: URL) async throws -> Bool {
        var probe = request(url, method: "PROPFIND")
        probe.setValue("0", forHTTPHeaderField: "Depth")
        let result = try await read(probe)
        let code = try status(result.1)
        if code == 404 { return false }
        guard code == 207 || code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        return true
    }

    func prepareFolders() async throws {
        if folderCache?.isPrepared(folderCacheKey) == true { return }
        let parent = root.deletingLastPathComponent()
        for folder in [parent, root, root.appendingPathComponent("blobs", isDirectory: true)] {
            if try await exists(folder) { continue }
            try await createFolder(folder)
        }
        folderCache?.markPrepared(folderCacheKey)
    }

    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool) {
        let (data, response) = try await read(request(root.appendingPathComponent("index.json"), method: "GET"))
        let code = try status(response)
        if code == 404 { return (WebDAVManifest(), nil, false) }
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        let manifest = try JSONDecoder().decode(WebDAVManifest.self, from: data)
        guard manifest.version == 1 else { throw WebDAVSyncError.unsupportedManifest }
        return (manifest, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), true)
    }

    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws {
        var request = request(root.appendingPathComponent("index.json"), method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        } else if !existed {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        let (_, response) = try await session.upload(for: request, from: JSONEncoder().encode(manifest))
        let code = try status(response)
        if code == 412 { throw WebDAVSyncError.concurrentChange }
        guard (200...299).contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
    }

    func deleteBlob(_ hash: String) async throws {
        let (_, response) = try await session.data(for: request(try blobURL(hash), method: "DELETE"))
        let code = try status(response)
        guard (200...299).contains(code) || code == 404 else { throw WebDAVSyncError.unexpectedResponse(code) }
    }

    private var statisticsFolder: URL { root.appendingPathComponent("statistics", isDirectory: true) }

    func fetchLegacyReadingStatistics() async throws -> ReadingStatisticsSync? {
        let (data, response) = try await read(request(root.appendingPathComponent("reading-statistics.json"), method: "GET"))
        let code = try status(response)
        if code == 404 { return nil }
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        // 旧文件只读取合并，格式不对时忽略，不阻断新格式的同步。
        guard let snapshot = try? JSONDecoder().decode(ReadingStatisticsSync.self, from: data), snapshot.isValid else {
            return nil
        }
        return snapshot
    }

    func listDeviceStatistics() async throws -> [ReadingStatisticsRemoteEntry] {
        var list = request(statisticsFolder, method: "PROPFIND")
        list.setValue("1", forHTTPHeaderField: "Depth")
        list.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        list.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await read(list)
        let code = try status(response)
        if code == 404 {
            try await createFolder(statisticsFolder)
            return []
        }
        guard code == 207 else { throw WebDAVSyncError.unexpectedResponse(code) }
        var seen = Set<String>()
        return WebDAVMultistatus.responses(in: data).compactMap { item in
            let name = (item.href.removingPercentEncoding ?? item.href).split(separator: "/").last.map(String.init) ?? ""
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard ReadingDeviceStatisticsFile.isValidDeviceID(id), seen.insert(id).inserted else { return nil }
            return ReadingStatisticsRemoteEntry(deviceID: id, version: item.version)
        }
    }

    func fetchDeviceStatistics(_ deviceID: String) async throws -> ReadingDeviceStatisticsFile? {
        guard ReadingDeviceStatisticsFile.isValidDeviceID(deviceID) else { return nil }
        let (data, response) = try await read(request(statisticsFolder.appendingPathComponent("\(deviceID).json"), method: "GET"))
        let code = try status(response)
        if code == 404 { return nil }
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        guard let file = try? JSONDecoder().decode(ReadingDeviceStatisticsFile.self, from: data),
              file.isValid, file.deviceID == deviceID else { return nil }
        return file
    }

    /// 只写本机文件，直接覆盖；其他设备不会写这个文件。返回服务器给出的 ETag（如有）。
    func putDeviceStatistics(_ data: Data, deviceID: String) async throws -> String? {
        guard ReadingDeviceStatisticsFile.isValidDeviceID(deviceID) else { throw WebDAVSyncError.invalidStatistics }
        var put = request(statisticsFolder.appendingPathComponent("\(deviceID).json"), method: "PUT")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: put, from: data)
        let code = try status(response)
        guard (200...299).contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
    }

    private func createFolder(_ folder: URL) async throws {
        var create = request(folder, method: "MKCOL")
        create.httpBody = Data()
        create.setValue("0", forHTTPHeaderField: "Content-Length")
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: create)
        } catch let error as URLError where error.code == .networkConnectionLost {
            // 创建请求可能已经在服务器执行；先查远端，避免盲目重复写入。
            if try await exists(folder) { return }
            throw error
        }
        let code = try status(result.1)
        guard [201, 405].contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
    }

    private func blobURL(_ hash: String) throws -> URL {
        guard WebDAVAsset.isValidHash(hash) else { throw WebDAVSyncError.invalidAsset }
        return root.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(hash)
    }

    func uploadBlob(_ file: URL, hash: String) async throws {
        let url = try blobURL(hash)
        if try await exists(url) { return }
        var put = request(url, method: "PUT")
        put.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await session.upload(for: put, fromFile: file)
        let code = try status(response)
        guard (200...299).contains(code) || code == 412 else { throw WebDAVSyncError.unexpectedResponse(code) }
    }

    func downloadBlob(_ hash: String) async throws -> URL {
        let get = request(try blobURL(hash), method: "GET")
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: get)
        } catch let error as URLError where error.code == .networkConnectionLost {
            result = try await session.download(for: get)
        }
        let (temporary, response) = result
        let code = try status(response)
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        let actualHash = try await Task.detached(priority: .utility) {
            try WebDAVFileHash.sha256(temporary)
        }.value
        guard actualHash == hash else { throw WebDAVSyncError.invalidAsset }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// `statistics/` 中的一个设备文件。`version` 取 ETag，没有时用修改时间与大小，都没有为 nil。
struct ReadingStatisticsRemoteEntry: Equatable {
    let deviceID: String
    let version: String?
}

/// 阅读统计同步的本机缓存，用来少发请求：版本未变的设备文件不再下载，内容未变的本机文件不再上传，
/// 旧版合并文件每天最多检查一次。缓存只在同步成功并套用到本机后保存；丢失只会多发请求，不影响结果。
struct ReadingStatisticsSyncCache: Codable, Equatable {
    static let legacyCheckInterval: TimeInterval = 24 * 60 * 60
    /// 缓存格式。0.20.0(72) 合并设备名称有误，其缓存记下的版本对应的名称未保存；
    /// 格式不符时丢弃设备版本，重新读取一次全部设备文件。
    static let currentFormat = 2
    var format: Int? = currentFormat

    /// 缓存所属的服务器（用户名@地址）；与当前设置不同时整份作废。
    var server: String?
    /// 已合并到本机的各设备文件版本。
    var deviceVersions: [String: String] = [:]
    /// 上次上传的本机文件内容哈希。
    var uploadedHash: String?
    var legacyCheckedAt: Date?

    init(server: String? = nil) { self.server = server }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        format = try container.decodeIfPresent(Int.self, forKey: .format)
        deviceVersions = try container.decodeIfPresent([String: String].self, forKey: .deviceVersions) ?? [:]
        uploadedHash = try container.decodeIfPresent(String.self, forKey: .uploadedHash)
        legacyCheckedAt = try container.decodeIfPresent(Date.self, forKey: .legacyCheckedAt)
    }
}

/// 阅读统计的远端：`statistics/<设备 ID>.json` 每台设备一个文件；
/// `reading-statistics.json` 是 0.18–0.19 私密测试版写入的合并文件，新版只读取、不再写入。
protocol ReadingStatisticsRemote {
    /// 旧版合并文件；不存在或格式不对时返回 nil。
    func fetchLegacyReadingStatistics() async throws -> ReadingStatisticsSync?
    /// `statistics/` 中的设备文件及版本；目录不存在时创建并返回空。
    func listDeviceStatistics() async throws -> [ReadingStatisticsRemoteEntry]
    /// 指定设备的文件；不存在、格式不对或 ID 不符时返回 nil。
    func fetchDeviceStatistics(_ deviceID: String) async throws -> ReadingDeviceStatisticsFile?
    /// 写入本机文件，返回服务器给出的新 ETag（如有）。
    func putDeviceStatistics(_ data: Data, deviceID: String) async throws -> String?
}

/// 合并远端全部设备文件与旧版文件，再写回本机文件。合并按设备取最大值，重复或中断的同步不会重复累计；
/// 每台设备只写自己的文件，同时同步也不会互相覆盖。
struct ReadingStatisticsSynchronizer {
    let remote: any ReadingStatisticsRemote

    func sync(_ local: ReadingStatisticsSync, deviceID: String,
              cache: ReadingStatisticsSyncCache = ReadingStatisticsSyncCache(),
              now: Date = Date()) async throws -> (ReadingStatisticsSync, ReadingStatisticsSyncCache) {
        guard local.isValid, ReadingDeviceStatisticsFile.isValidDeviceID(deviceID) else {
            throw WebDAVSyncError.invalidStatistics
        }
        var merged = local
        var cache = cache
        if cache.format != ReadingStatisticsSyncCache.currentFormat {
            cache.deviceVersions = [:]
            cache.format = ReadingStatisticsSyncCache.currentFormat
        }
        if cache.legacyCheckedAt.map({ now.timeIntervalSince($0) >= ReadingStatisticsSyncCache.legacyCheckInterval }) ?? true {
            if let legacy = try await remote.fetchLegacyReadingStatistics() { merged = .merged(merged, legacy) }
            cache.legacyCheckedAt = now
        }
        let entries = try await remote.listDeviceStatistics()
        // 也读取本机文件：从备份恢复的另一台设备可能沿用相同 ID，取最大值保留两边已上传的时长。
        for entry in entries {
            try Task.checkCancellation()
            if let version = entry.version, cache.deviceVersions[entry.deviceID] == version { continue }
            if let file = try await remote.fetchDeviceStatistics(entry.deviceID) { merged = .merged(merged, file.snapshot) }
            cache.deviceVersions[entry.deviceID] = entry.version
        }
        let listed = Set(entries.map(\.deviceID))
        cache.deviceVersions = cache.deviceVersions.filter { listed.contains($0.key) }
        try Task.checkCancellation()

        let own = ReadingDeviceStatisticsFile(deviceID: deviceID, device: merged.deviceInfo?[deviceID],
                                              statistics: merged.devices[deviceID] ?? ReadingStatistics())
        guard own.isValid else { throw WebDAVSyncError.invalidStatistics }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(own)
        let hash = FileContentHash.sha256(data)
        // 内容没变且远端文件还在时不再上传。
        if hash != cache.uploadedHash || !listed.contains(deviceID) {
            let version = try await remote.putDeviceStatistics(data, deviceID: deviceID)
            cache.uploadedHash = hash
            // 没有新 ETag 时清掉旧版本，下次会重新读一次本机文件。
            cache.deviceVersions[deviceID] = version
        }
        return (merged, cache)
    }
}

/// 从 PROPFIND 的 207 Multi-Status 响应中取出各条目的 href 与版本属性；命名空间前缀因服务器而异。
enum WebDAVMultistatus {
    struct Item: Equatable {
        var href = ""
        var etag: String?
        var lastModified: String?
        var contentLength: String?

        /// 优先 ETag；没有时用修改时间与大小拼成版本，二者都没有则无法判断是否变化。
        var version: String? {
            if let etag, !etag.isEmpty { return etag }
            guard let lastModified, !lastModified.isEmpty else { return nil }
            return "\(lastModified)|\(contentLength ?? "")"
        }
    }

    static func responses(in data: Data) -> [Item] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        return collector.items
    }

    static func hrefs(in data: Data) -> [String] { responses(in: data).map(\.href) }

    private final class Collector: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch elementName {
            case "response": current = Item()
            case "href", "getetag", "getlastmodified", "getcontentlength": text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text? += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "href": current?.href = value ?? ""
            case "getetag": current?.etag = value
            case "getlastmodified": current?.lastModified = value
            case "getcontentlength": current?.contentLength = value
            case "response":
                if let current { items.append(current) }
                current = nil
            default: return
            }
            text = nil
        }
    }
}
