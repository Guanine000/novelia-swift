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
    /// 条件写入清单：已有清单必须有强 ETag；坚果云首次创建使用禁止覆盖的 MOVE。
    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws
    /// 上传以内容哈希命名的文件；远端已有时跳过。
    func uploadBlob(_ file: URL, hash: String) async throws
    /// 下载并校验哈希，返回调用方负责删除的临时文件。
    func downloadBlob(_ hash: String) async throws -> URL
    /// 删除不再被清单引用的 blob；不存在也视为成功。
    func deleteBlob(_ hash: String) async throws
    /// 列出服务器 blobs/ 中已有的文件（内容哈希）；服务器不支持列目录时返回 nil。
    /// 手动同步用它找出清单引用却已不在服务器上的文件（例如被手动删除），以便补传。
    func listBlobs() async throws -> Set<String>?
}

extension WebDAVRemote {
    func listBlobs() async throws -> Set<String>? { nil }
}

// 兼容名称，供现有同步测试与调用方使用。
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
         configuration: URLSessionConfiguration = .ephemeral, folderCache: WebDAVFolderCache? = nil, webEPUBIdentity: Bool = false) throws {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw WebDAVSyncError.invalidURL }
        base = url
        root = url.appendingPathComponent("NoveliaSync", isDirectory: true)
                  .appendingPathComponent(webEPUBIdentity ? "web-epub-v1" : "v1", isDirectory: true)
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        session = URLSession(configuration: configuration, delegate: WebDAVRedirectGuard(), delegateQueue: nil)
        self.folderCache = folderCache
        folderCacheKey = Self.serverKey(username: username, base: url) + (webEPUBIdentity ? "|web-epub-v1" : "")
    }

    /// 缓存用的服务器标识。
    static func serverKey(username: String, base: URL) -> String { "\(username)@\(base.absoluteString)" }
    var serverKey: String { folderCacheKey }

    deinit {
        session.finishTasksAndInvalidate()
    }

    private func request(_ url: URL, method: String) -> URLRequest {
        // 清单正文与版本必须来自同一次服务器读取；旧缓存会使条件写入持续冲突，
        // 也会把写入后的读回误判为其他设备覆盖。统计与目录同样不使用 HTTP 缓存。
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
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

    // 参考 GPL-3.0-only：Copyright (C) 2026 Novelia Android contributors.
    // 2026-10-17 修改：WebDavClient.kt @ 44be26d 的 Swift 适配，含强版本读取、坚果云条件头与禁止覆盖创建。
    private var verifiedCreationProtection = false
    private var isNutcloud: Bool { base.host?.lowercased() == "dav.jianguoyun.com" && (base.port ?? 443) == 443 }

    /// 内部保持带引号的强版本；不能去掉 W/ 将弱版本伪装为强版本。
    static func strongETag(_ value: String?) -> String? {
        guard let value else { return nil }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let token = value.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, token.utf8.count <= 1024, !token.uppercased().hasPrefix("W/"), token != "*" else { return nil }
        let quoted = token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2
        if !quoted && !token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array("._:=+-/".utf8).contains($0) }) { return nil }
        let opaque = quoted ? String(token.dropFirst().dropLast()) : token
        guard !opaque.isEmpty, opaque.utf8.allSatisfy({ $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80 }) else { return nil }
        return "\"\(opaque)\""
    }

    private func conditionalETag(_ value: String) throws -> String {
        guard let strong = Self.strongETag(value) else { throw WebDAVSyncError.unsupportedConditions }
        return isNutcloud ? String(strong.dropFirst().dropLast()) : strong
    }

    /// GET 无版本时按属性版本重新读取，并确认服务确实执行读取条件；不配对旧正文与新版本。
    private func versionedRead(_ url: URL) async throws -> (Data, String)? {
        let (data, response) = try await read(request(url, method: "GET"))
        let code = try status(response)
        if code == 404 { return nil }
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        if let etag = Self.strongETag((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")) { return (data, etag) }
        var prop = request(url, method: "PROPFIND")
        prop.setValue("0", forHTTPHeaderField: "Depth")
        prop.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        prop.httpBody = Data(#"<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>"#.utf8)
        let (properties, propertyResponse) = try await read(prop)
        let propertyCode = try status(propertyResponse)
        if propertyCode == 404 { throw WebDAVSyncError.concurrentChange }
        guard propertyCode == 207 || propertyCode == 200 else { throw WebDAVSyncError.unexpectedResponse(propertyCode) }
        guard let etag = WebDAVVersionProperty.etag(in: properties, target: url).flatMap(Self.strongETag) else {
            throw WebDAVSyncError.unsupportedConditions
        }
        var checked = request(url, method: "GET")
        checked.setValue(try conditionalETag(etag), forHTTPHeaderField: "If-Match")
        let (freshData, freshResponse) = try await read(checked)
        let freshCode = try status(freshResponse)
        if freshCode == 404 || freshCode == 412 { throw WebDAVSyncError.concurrentChange }
        guard freshCode == 200 else { throw WebDAVSyncError.unexpectedResponse(freshCode) }
        if let returned = (freshResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
           Self.strongETag(returned) != etag { throw WebDAVSyncError.concurrentChange }
        var invalid = request(url, method: "GET")
        invalid.setValue(try conditionalETag("\"novelia-absent-\(UUID().uuidString)\""), forHTTPHeaderField: "If-Match")
        let (_, rejection) = try await read(invalid)
        let rejectedCode = try status(rejection)
        if rejectedCode == 404 { throw WebDAVSyncError.concurrentChange }
        guard rejectedCode == 412 else {
            if rejectedCode != 200 && rejectedCode != 304 { throw WebDAVSyncError.unexpectedResponse(rejectedCode) }
            throw WebDAVSyncError.unsupportedConditions
        }
        return (freshData, etag)
    }

    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool) {
        guard let (data, etag) = try await versionedRead(root.appendingPathComponent("index.json")) else {
            return (WebDAVManifest(), nil, false)
        }
        let manifest = try JSONDecoder().decode(WebDAVManifest.self, from: data)
        guard manifest.version == 1 else { throw WebDAVSyncError.unsupportedManifest }
        return (manifest, etag, true)
    }

    func putManifest(_ manifest: WebDAVManifest, etag: String?, existed: Bool) async throws {
        let url = root.appendingPathComponent("index.json")
        let data = try JSONEncoder().encode(manifest)
        if !existed {
            guard etag == nil else { throw WebDAVSyncError.concurrentChange }
            if isNutcloud {
                try await verifyCreationProtection()
                try await createByMove(data, to: url)
                return
            }
        } else if etag == nil { throw WebDAVSyncError.unsupportedConditions }
        var put = request(url, method: "PUT")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { put.setValue(try conditionalETag(etag), forHTTPHeaderField: "If-Match") }
        else { put.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await session.upload(for: put, from: data)
        let code = try status(response)
        if code == 412 { throw WebDAVSyncError.concurrentChange }
        guard (200...299).contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
        // PUT 不回传强版本时，读回本次正文后才确认成功；有其他写者则重新合并。
        if Self.strongETag((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")) == nil {
            guard let (saved, _) = try await versionedRead(url), saved == data else { throw WebDAVSyncError.concurrentChange }
        }
    }

    /// 首次建立共享清单前，在独立随机目标验证禁止覆盖；不拿真实 index.json 试错。
    private func verifyCreationProtection() async throws {
        guard !verifiedCreationProtection else { return }
        let target = root.appendingPathComponent("novelia-probe-\(UUID().uuidString).cache")
        let first = Data("novelia-probe-\(UUID().uuidString)".utf8)
        let second = Data("novelia-probe-\(UUID().uuidString)".utf8)
        do {
            try await createByMove(first, to: target)
            guard let (saved, version) = try await versionedRead(target), saved == first else { throw WebDAVSyncError.unsupportedConditions }
            do {
                try await createByMove(second, to: target)
                throw WebDAVSyncError.unsupportedConditions
            } catch WebDAVSyncError.concurrentChange {
                // 冲突状态不足以证明没有覆盖，还要核验原正文和版本。
            }
            guard let (unchanged, currentVersion) = try await versionedRead(target), unchanged == first, currentVersion == version else {
                throw WebDAVSyncError.unsupportedConditions
            }
            var update = request(target, method: "PUT")
            update.setValue(try conditionalETag(version), forHTTPHeaderField: "If-Match")
            let (_, updatedResponse) = try await session.upload(for: update, from: second)
            let updatedCode = try status(updatedResponse)
            guard (200...299).contains(updatedCode) else { throw WebDAVSyncError.unexpectedResponse(updatedCode) }
            guard let (updated, updatedVersion) = try await versionedRead(target), updated == second, updatedVersion != version else {
                throw WebDAVSyncError.unsupportedConditions
            }
            let (_, staleResponse) = try await session.upload(for: update, from: first)
            let staleCode = try status(staleResponse)
            guard staleCode == 412 else {
                if !(200...299).contains(staleCode) { throw WebDAVSyncError.unexpectedResponse(staleCode) }
                throw WebDAVSyncError.unsupportedConditions
            }
            guard let (preserved, preservedVersion) = try await versionedRead(target), preserved == second, preservedVersion == updatedVersion else {
                throw WebDAVSyncError.unsupportedConditions
            }
            try await removeTemporary(target)
            verifiedCreationProtection = true
        } catch {
            try? await removeTemporary(target)
            throw error
        }
    }

    /// 随机源只属于本次操作；目标从不删除，失败也不回退到覆盖 PUT。
    private func createByMove(_ data: Data, to target: URL) async throws {
        let source = root.appendingPathComponent("novelia-upload-\(UUID().uuidString).cache")
        do {
            var put = request(source, method: "PUT")
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, uploaded) = try await session.upload(for: put, from: data)
            let uploadCode = try status(uploaded)
            guard (200...299).contains(uploadCode) else { throw WebDAVSyncError.unexpectedResponse(uploadCode) }
            for attempt in 0..<3 {
                try Task.checkCancellation()
                var move = request(source, method: "MOVE")
                let path = URLComponents(url: target, resolvingAgainstBaseURL: false)!.percentEncodedPath
                move.setValue(attempt == 2 ? path : target.absoluteString, forHTTPHeaderField: "Destination")
                move.setValue("F", forHTTPHeaderField: "Overwrite")
                let (_, response) = try await session.data(for: move)
                let code = try status(response)
                if (200...299).contains(code) {
                    guard let (saved, _) = try await versionedRead(target), saved == data else { throw WebDAVSyncError.concurrentChange }
                    try? await removeTemporary(source)
                    return
                }
                if code == 412 { throw WebDAVSyncError.concurrentChange }
                guard code == 409 || code == 404 else { throw WebDAVSyncError.unexpectedResponse(code) }
                // 坚果云已有目标也可能返回 409；只有确切目标不存在时才重试。
                let (_, existing) = try await read(request(target, method: "GET"))
                let existingCode = try status(existing)
                if existingCode == 200 { throw WebDAVSyncError.concurrentChange }
                guard existingCode == 404 else { throw WebDAVSyncError.unexpectedResponse(existingCode) }
                guard attempt < 2 else { throw WebDAVSyncError.unexpectedResponse(code) }
                let (currentSource, sourceResponse) = try await read(request(source, method: "GET"))
                guard try status(sourceResponse) == 200, currentSource == data else { throw WebDAVSyncError.concurrentChange }
                if attempt == 0 { try await createFolder(root) }
            }
        } catch {
            // 响应丢失也可能留下源；只清理本次随机地址，不触碰正式目标。
            try? await removeTemporary(source)
            throw error
        }
    }

    private func removeTemporary(_ url: URL) async throws {
        let (_, response) = try await session.data(for: request(url, method: "DELETE"))
        let code = try status(response)
        guard (200...299).contains(code) || code == 404 else { throw WebDAVSyncError.unexpectedResponse(code) }
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

    func listBlobs() async throws -> Set<String>? {
        var list = request(root.appendingPathComponent("blobs", isDirectory: true), method: "PROPFIND")
        list.setValue("1", forHTTPHeaderField: "Depth")
        list.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        list.httpBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (data, response) = try await read(list)
        let code = try status(response)
        if code == 404 { return [] }
        guard code == 207 else { return nil }
        return Set(WebDAVMultistatus.hrefs(in: data).compactMap { href in
            let name = (href.removingPercentEncoding ?? href).split(separator: "/").last.map(String.init) ?? ""
            return WebDAVAsset.isValidHash(name) ? name : nil
        })
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
        // 清单引用的文件不在服务器上（例如被手动删除）：给出可操作的提示，而不是“路径不存在”。
        if code == 404 { throw WebDAVSyncError.missingBlob }
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

/// 版本属性只接受确切目标、DAV 命名空间和成功 propstat；拒绝畸形或过大的 XML。
private final class WebDAVVersionProperty: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var href = ""
    private var pendingETag: String?
    private var propertyStatus = ""
    private var versions: [String] = []
    private var matches: [String] = []
    private let target: URL
    private init(target: URL) { self.target = target }

    static func etag(in data: Data, target: URL) -> String? {
        guard data.count <= 1_048_576, data.range(of: Data("<!DOCTYPE".utf8)) == nil else { return nil }
        let reader = WebDAVVersionProperty(target: target)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.matches.count == 1 else { return nil }
        return reader.matches[0]
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = namespaceURI == "DAV:" ? elementName : ""
        stack.append(name)
        text = ""
        if name == "response" { href = ""; versions = [] }
        if name == "propstat" { pendingETag = nil; propertyStatus = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !stack.isEmpty { stack.removeLast() }; text = "" }
        guard namespaceURI == "DAV:" else { return }
        let parent = stack.dropLast().last
        switch elementName {
        case "href" where parent == "response": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getetag" where parent == "prop": pendingETag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "status" where parent == "propstat": propertyStatus = text
        case "propstat":
            if propertyStatus.split(separator: " ").dropFirst().first == "200", let pendingETag { versions.append(pendingETag) }
        case "response":
            guard let url = URL(string: href, relativeTo: target)?.absoluteURL,
                  url.scheme == target.scheme, url.host == target.host,
                  (url.port ?? 443) == (target.port ?? 443), url.path == target.path,
                  url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { return }
            matches += versions
        default: break
        }
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
