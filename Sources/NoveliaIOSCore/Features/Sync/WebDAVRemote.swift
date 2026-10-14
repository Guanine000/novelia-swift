import Foundation

// WebDAV 远端访问：同步流程只依赖 `WebDAVRemote`，`WebDAVClient` 为 HTTP 实现。
// 远端布局：<地址>/NoveliaSync/v1/index.json 为清单，blobs/<sha256> 为书籍与资源文件。

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

/// 每次同步新建一个客户端；释放时让会话失效，否则带 delegate 的 URLSession 会一直被系统持有。
final class WebDAVClient: WebDAVRemote, ReadingStatisticsRemote {
    let base: URL
    let root: URL
    let authorization: String
    /// 仅供测试检查会话的生命周期。
    let session: URLSession

    /// `configuration` 仅供测试注入 URLProtocol；应用使用默认的临时会话。
    init(address: String, username: String, password: String,
         configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw WebDAVSyncError.invalidURL }
        base = url
        root = url.appendingPathComponent("NoveliaSync", isDirectory: true)
                  .appendingPathComponent("v1", isDirectory: true)
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        session = URLSession(configuration: configuration, delegate: WebDAVRedirectGuard(), delegateQueue: nil)
    }

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
        let parent = root.deletingLastPathComponent()
        for folder in [parent, root, root.appendingPathComponent("blobs", isDirectory: true)] {
            if try await exists(folder) { continue }
            var create = request(folder, method: "MKCOL")
            create.httpBody = Data()
            create.setValue("0", forHTTPHeaderField: "Content-Length")
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: create)
            } catch let error as URLError where error.code == .networkConnectionLost {
                // 创建请求可能已经在服务器执行；先查远端，避免盲目重复写入。
                if try await exists(folder) { continue }
                throw error
            }
            let code = try status(result.1)
            guard [201, 405].contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
        }
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

    func fetchReadingStatistics() async throws -> (ReadingStatisticsSync, String?, Bool) {
        let (data, response) = try await read(request(root.appendingPathComponent("reading-statistics.json"), method: "GET"))
        let code = try status(response)
        if code == 404 { return (ReadingStatisticsSync(), nil, false) }
        guard code == 200 else { throw WebDAVSyncError.unexpectedResponse(code) }
        let snapshot = try JSONDecoder().decode(ReadingStatisticsSync.self, from: data)
        guard snapshot.isValid else { throw WebDAVSyncError.invalidStatistics }
        return (snapshot, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), true)
    }

    func putReadingStatistics(_ snapshot: ReadingStatisticsSync, etag: String?, existed: Bool) async throws {
        guard snapshot.isValid else { throw WebDAVSyncError.invalidStatistics }
        // 不允许无条件覆盖已存在的统计，避免多设备同时同步丢掉计时记录。
        guard !existed || etag != nil else { throw WebDAVSyncError.missingStatisticsETag }
        var put = request(root.appendingPathComponent("reading-statistics.json"), method: "PUT")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { put.setValue(etag, forHTTPHeaderField: "If-Match") }
        else { put.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (_, response) = try await session.upload(for: put, from: JSONEncoder().encode(snapshot))
        let code = try status(response)
        if code == 412 { throw WebDAVSyncError.concurrentChange }
        guard (200...299).contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
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

protocol ReadingStatisticsRemote {
    func fetchReadingStatistics() async throws -> (ReadingStatisticsSync, String?, Bool)
    func putReadingStatistics(_ snapshot: ReadingStatisticsSync, etag: String?, existed: Bool) async throws
}

struct ReadingStatisticsSynchronizer {
    let remote: any ReadingStatisticsRemote

    func sync(_ local: ReadingStatisticsSync) async throws -> ReadingStatisticsSync {
        guard local.isValid else { throw WebDAVSyncError.invalidStatistics }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (snapshot, etag, existed) = try await remote.fetchReadingStatistics()
            guard snapshot.isValid else { throw WebDAVSyncError.invalidStatistics }
            let merged = ReadingStatisticsSync.merged(local, snapshot)
            do {
                try Task.checkCancellation()
                try await remote.putReadingStatistics(merged, etag: etag, existed: existed)
                return merged
            } catch WebDAVSyncError.concurrentChange where attempt < 2 {
                continue
            }
        }
        throw WebDAVSyncError.concurrentChange
    }
}
