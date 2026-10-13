import CryptoKit
import Foundation
import Security
import SwiftUI

@MainActor
enum ReadingPositionSync {
    private static let key = "readingPositions.v1"

    static func all() -> [String: SyncedReadingPosition] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: SyncedReadingPosition].self, from: data)) ?? [:]
    }

    static func recordWeb(id: String, chapterIndex: Int) {
        var positions = all()
        positions["web:\(id)"] = SyncedReadingPosition(chapterIndex: chapterIndex, fraction: nil, updatedAt: Date())
        save(positions)
    }

    static func recordEPUB(hash: String, fraction: Double, spineIndex: Int, chapterOffset: Int?, chapterProgression: Double?) {
        var positions = all()
        positions["epub:\(hash)"] = SyncedReadingPosition(chapterIndex: spineIndex,
            fraction: min(1, max(0, fraction)), updatedAt: Date(), chapterOffset: chapterOffset,
            chapterProgression: chapterProgression.map { min(1, max(0, $0)) })
        save(positions)
    }

    static func epubPosition(hash: String) -> SyncedReadingPosition? { all()["epub:\(hash)"] }

    /// 滚动和分页阅读器共用的 TXT 阅读位置，以书籍文件哈希同步。
    static func recordTXT(hash: String, position: TXTReadingPosition) {
        var positions = all()
        positions["txt:\(hash)"] = SyncedReadingPosition(chapterIndex: position.chapter, fraction: nil, updatedAt: Date(),
            chapterOffset: position.offset, unit: position.unit, unitCount: position.unitCount)
        save(positions)
    }

    static func txtPosition(hash: String) -> TXTReadingPosition? {
        if let synced = all()["txt:\(hash)"], let chapter = synced.chapterIndex {
            return TXTReadingPosition(chapter: chapter, unit: synced.unit, offset: synced.chapterOffset, unitCount: synced.unitCount)
        }
        // 0.12.0（52）测试构建将 TXT 阅读位置保存在仅本地使用的键中。
        return TXTReadingPosition.legacy(hash: hash)
    }

    static func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        var positions = all()
        let progress = ReadingProgressStore()
        for book in webBooks {
            let key = "web:\(book.id)"
            if positions[key] == nil, let index = progress.chapterIndex(novelID: book.id) {
                positions[key] = SyncedReadingPosition(
                    chapterIndex: index, fraction: nil,
                    updatedAt: progress.updatedAt(novelID: book.id) ?? .distantPast)
            }
        }
        positions = SyncedReadingPosition.merged(positions, remote)
        for book in webBooks {
            if let position = positions["web:\(book.id)"], let index = position.chapterIndex {
                progress.save(chapterIndex: index, updatedAt: position.updatedAt, novelID: book.id)
            }
        }
        save(positions)
    }

    private static func save(_ positions: [String: SyncedReadingPosition]) {
        if let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum WebDAVFileHash {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct WebDAVAsset: Codable {
    let filename: String
    let hash: String
}

private struct WebDAVBook<Record: Codable>: Codable {
    let record: Record
    let assets: [WebDAVAsset]
}

private struct WebDAVManifest: Codable {
    var version = 1
    var webBooks: [WebDAVBook<DownloadedWebNovel>] = []
    var wenkuBooks: [WebDAVBook<LocalWenkuEPUB>] = []
    var positions: [String: SyncedReadingPosition] = [:]
    var blockedTags: [String: SyncedBlockedTag]? = nil
    var backgrounds: [String: SyncedReaderBackground]? = nil
    var fonts: [String: SyncedImportedFont]? = nil
    /// 书库系列与书籍归属；随书籍同步，旧版应用解码时忽略。
    var librarySeries: LibrarySeriesState? = nil
}

private enum WebDAVSyncError: LocalizedError {
    case invalidURL
    case missingCredentials
    case unexpectedResponse(Int)
    case unsupportedManifest
    case invalidAsset
    case concurrentChange

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
        case .concurrentChange: "另一台设备刚更新了同步数据，请重新同步。"
        }
    }
}

private final class WebDAVRedirectGuard: NSObject, URLSessionTaskDelegate {
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

private struct WebDAVClient {
    let base: URL
    let root: URL
    let authorization: String
    private let session = URLSession(configuration: .ephemeral, delegate: WebDAVRedirectGuard(), delegateQueue: nil)

    init(address: String, username: String, password: String) throws {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw WebDAVSyncError.invalidURL }
        base = url
        root = url.appendingPathComponent("NoveliaSync", isDirectory: true)
                  .appendingPathComponent("v1", isDirectory: true)
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
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

    private func blobURL(_ hash: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw WebDAVSyncError.invalidAsset
        }
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

@MainActor
final class WebDAVSyncStore: ObservableObject {
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: SettingsKey.WebDAV.enabled) } }
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: SettingsKey.WebDAV.address) } }
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: SettingsKey.WebDAV.username) } }
    @Published var syncBooks: Bool { didSet { UserDefaults.standard.set(syncBooks, forKey: SettingsKey.WebDAV.syncBooks) } }
    @Published var syncTags: Bool { didSet { UserDefaults.standard.set(syncTags, forKey: SettingsKey.WebDAV.syncTags) } }
    @Published var syncBackgrounds: Bool { didSet { UserDefaults.standard.set(syncBackgrounds, forKey: SettingsKey.WebDAV.syncBackgrounds) } }
    @Published var syncFonts: Bool { didSet { UserDefaults.standard.set(syncFonts, forKey: SettingsKey.WebDAV.syncFonts) } }
    @Published var password: String = ""
    @Published private(set) var isSyncing = false
    @Published private(set) var progressDetail = ""
    @Published private(set) var completedUnits = 0
    @Published private(set) var totalUnits = 1
    @Published var message: String?

    private let keychainService = "cc.novelia.ios.port.webdav"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.enabled) as? Bool ?? true
        syncBooks = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncBooks) as? Bool ?? true
        syncTags = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncTags) as? Bool ?? true
        syncBackgrounds = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncBackgrounds)
        syncFonts = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncFonts)
        address = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.address) ?? ""
        username = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.username) ?? ""
        password = Self.readPassword(service: keychainService) ?? ""
    }

    func sync(web: WebNovelDownloadStore, wenku: WenkuLocalLibraryStore) async {
        guard isEnabled else {
            message = "WebDAV 同步已关闭，请先在“我的 → WebDAV 同步”中开启。"
            return
        }
        guard !isSyncing else { return }
        let includesBooks = syncBooks
        let includesTags = syncTags
        let includesBackgrounds = syncBackgrounds
        let includesFonts = syncFonts
        guard includesBooks || includesTags || includesBackgrounds || includesFonts else {
            message = "请至少开启一项同步内容。"
            return
        }
        isSyncing = true
        message = nil
        completedUnits = 0
        totalUnits = 1
        progressDetail = "正在连接服务器…"
        defer { isSyncing = false }
        var stage = "连接服务器"
        do {
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty, !account.contains(":"), !password.isEmpty else {
                throw WebDAVSyncError.missingCredentials
            }
            try savePassword()
            let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                          username: account, password: password)
            try await client.verifyConnection()
            stage = "创建同步目录"
            progressDetail = "正在检查同步目录…"
            try await client.prepareFolders()
            stage = "读取远端书目"
            progressDetail = "正在读取远端书目…"
            let (fetchedManifest, etag, existed) = try await client.fetchManifest()
            var manifest = fetchedManifest
            var imported = 0
            if includesBooks {
                let remoteWeb = manifest.webBooks
                let remoteWenku = manifest.wenkuBooks
                let localWebByID = Dictionary(uniqueKeysWithValues: web.books.map { ($0.id, $0) })
                let localWenkuByID = Dictionary(uniqueKeysWithValues: wenku.books.map { ($0.id, $0) })
                let remoteWebByID = Dictionary(uniqueKeysWithValues: remoteWeb.map { ($0.record.id, $0) })
                let remoteWenkuByID = Dictionary(uniqueKeysWithValues: remoteWenku.map { ($0.record.id, $0) })
                let remoteWebWins = remoteWeb.filter { item in
                    guard let local = localWebByID[item.record.id] else { return true }
                    return item.record.downloadedAt > local.downloadedAt
                }
                let localWebWins = web.books.filter { book in
                    guard let remote = remoteWebByID[book.id] else { return true }
                    return book.downloadedAt >= remote.record.downloadedAt
                }
                let remoteWenkuWins = remoteWenku.filter { item in
                    guard let local = localWenkuByID[item.record.id] else { return true }
                    return item.record.addedAt > local.addedAt
                }
                let localWenkuWins = wenku.books.filter { book in
                    guard let remote = remoteWenkuByID[book.id] else { return true }
                    return book.addedAt >= remote.record.addedAt
                }
                totalUnits = remoteWebWins.reduce(0) { $0 + $1.assets.count }
                    + remoteWenkuWins.reduce(0) { $0 + $1.assets.count }
                    + localWebWins.reduce(0) { $0 + web.syncFiles(for: $1).count }
                    + localWenkuWins.reduce(0) { $0 + wenku.syncFiles(for: $1).count }
                    + 1
                stage = "恢复远端下载"
                for item in remoteWebWins {
                    try Task.checkCancellation()
                    let files = try await download(item.assets, title: item.record.novel.title, with: client)
                    defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                    if localWebByID[item.record.id] != nil {
                        try web.replaceFromSync(item.record, files: files)
                    } else {
                        try web.restoreFromSync(item.record, files: files)
                        imported += 1
                    }
                }
                for item in remoteWenkuWins {
                    try Task.checkCancellation()
                    let files = try await download(item.assets, title: item.record.title, with: client)
                    defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                    if localWenkuByID[item.record.id] != nil {
                        try wenku.replaceFromSync(item.record, files: files)
                    } else {
                        try wenku.restoreFromSync(item.record, files: files)
                        imported += 1
                    }
                }
                ReadingPositionSync.merge(manifest.positions, webBooks: web.books)
                stage = "上传本地下载"
                for book in localWebWins {
                    try Task.checkCancellation()
                    let files = web.syncFiles(for: book)
                    guard files.count == 1 else {
                        throw WebDAVSyncError.invalidAsset
                    }
                    let saved = try await remoteBook(book, title: book.novel.title, files: files, client: client)
                    manifest.webBooks.removeAll { $0.record.id == book.id }
                    manifest.webBooks.append(saved)
                }
                for book in localWenkuWins {
                    try Task.checkCancellation()
                    let files = wenku.syncFiles(for: book)
                    guard files[book.filename] != nil else { throw WebDAVSyncError.invalidAsset }
                    let saved = try await remoteBook(book, title: book.title, files: files, client: client)
                    manifest.wenkuBooks.removeAll { $0.record.id == book.id }
                    manifest.wenkuBooks.append(saved)
                }
                let webKeys = Set(manifest.webBooks.map { "web:\($0.record.id)" })
                let assetHashes = (manifest.webBooks.flatMap(\.assets) + manifest.wenkuBooks.flatMap(\.assets)).map(\.hash)
                let fileKeys = Set(assetHashes.map { "epub:\($0)" } + assetHashes.map { "txt:\($0)" })
                manifest.positions = ReadingPositionSync.all().filter { webKeys.contains($0.key) || fileKeys.contains($0.key) }
                manifest.librarySeries = LibrarySeriesState.merged(LibraryStateStore.shared.series, manifest.librarySeries ?? LibrarySeriesState())
            }
            if includesTags {
                manifest.blockedTags = BlockedTagsStore.merged(BlockedTagsStore.shared.syncStates, manifest.blockedTags ?? [:])
            }
            var resourceFiles: [String: URL] = [:]
            var temporaryFiles: [URL] = []
            defer { temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
            if includesBackgrounds {
                stage = "同步阅读背景"; progressDetail = "正在同步背景颜色与竖横屏图片…"
                var backgrounds = manifest.backgrounds ?? [:]
                for dark in [false, true] {
                    let key = dark ? "dark" : "light"
                    let local = try ReaderBackgroundStore.shared.syncSnapshot(dark: dark)
                    if let remote = backgrounds[key], remote.updatedAt > local.updatedAt {
                        for hash in [remote.portraitHash, remote.landscapeHash].compactMap({ $0 }) {
                            let file = try await client.downloadBlob(hash)
                            temporaryFiles.append(file)
                            guard UIImage(contentsOfFile: file.path) != nil else { throw WebDAVSyncError.invalidAsset }
                            resourceFiles[hash] = file
                        }
                    } else {
                        backgrounds[key] = local
                        for landscape in [false, true] {
                            let file = ReaderBackgroundStore.shared.imageURL(dark: dark, landscape: landscape)
                            if FileManager.default.fileExists(atPath: file.path) {
                                try await client.uploadBlob(file, hash: WebDAVFileHash.sha256(file))
                            }
                        }
                    }
                }
                manifest.backgrounds = backgrounds
            }
            if includesFonts {
                stage = "同步导入字体"; progressDetail = "正在同步导入字体…"
                let local = try EPUBLocalFonts.syncSnapshot()
                let fonts = SyncedImportedFont.merged(local, manifest.fonts ?? [:])
                let files = try EPUBLocalFonts.syncFiles()
                for (hash, record) in fonts {
                    guard hash == record.hash, ["ttf", "otf", "ttc"].contains(record.format) else { throw WebDAVSyncError.invalidAsset }
                    if record.deleted { continue }
                    if let file = files[hash] { try await client.uploadBlob(file, hash: hash) }
                    else {
                        let file = try await client.downloadBlob(hash); temporaryFiles.append(file); resourceFiles[hash] = file
                    }
                }
                manifest.fonts = fonts
            }
            stage = "保存远端书目"
            progressDetail = "正在保存同步清单…"
            try await client.putManifest(manifest, etag: etag, existed: existed)
            if includesTags { BlockedTagsStore.shared.applySynced(manifest.blockedTags ?? [:]) }
            if includesBooks, let series = manifest.librarySeries { LibraryStateStore.shared.applySynced(series) }
            if includesBackgrounds {
                for dark in [false, true] {
                    if let value = manifest.backgrounds?[dark ? "dark" : "light"] {
                        try ReaderBackgroundStore.shared.applySync(value, dark: dark, files: resourceFiles)
                    }
                }
            }
            if includesFonts { try EPUBLocalFonts.applySync(manifest.fonts ?? [:], files: resourceFiles) }
            completedUnits += 1
            progressDetail = "同步完成"
            let bookSummary = includesBooks ? "恢复 \(imported) 本书，网络小说 \(web.books.count) 本，文库 \(wenku.books.count) 本。" : ""
            message = "同步完成：" + bookSummary + (includesTags ? "已同步屏蔽标签。" : "") + (includesBackgrounds ? "已同步阅读背景。" : "") + (includesFonts ? "已同步导入字体。" : "")
        } catch is CancellationError {
            progressDetail = "已取消同步"
            message = "同步已取消。已完成的文件不会回滚；远端目录清单只在最后阶段写入。"
        } catch let error as URLError where error.code == .cancelled {
            progressDetail = "已取消同步"
            message = "同步已取消。已完成的文件不会回滚；远端目录清单只在最后阶段写入。"
        } catch {
            let code = (error as? URLError).map { "（网络错误 \($0.code.rawValue)）" } ?? ""
            message = "同步失败（\(stage)）\(code)：\(error.localizedDescription)"
        }
    }

    private func remoteBook<Record: Codable>(_ record: Record, title: String, files: [String: URL],
                                              client: WebDAVClient) async throws -> WebDAVBook<Record> {
        var assets: [WebDAVAsset] = []
        for (filename, url) in files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            progressDetail = "正在上传：\(title) · \(filename)"
            let hash = try await Task.detached(priority: .utility) {
                try WebDAVFileHash.sha256(url)
            }.value
            try await client.uploadBlob(url, hash: hash)
            assets.append(WebDAVAsset(filename: filename, hash: hash))
            completedUnits += 1
        }
        return WebDAVBook(record: record, assets: assets)
    }

    private func download(_ assets: [WebDAVAsset], title: String,
                          with client: WebDAVClient) async throws -> [String: URL] {
        var files: [String: URL] = [:]
        do {
            for asset in assets {
                try Task.checkCancellation()
                guard !asset.filename.isEmpty, asset.filename == URL(fileURLWithPath: asset.filename).lastPathComponent,
                      asset.filename != ".", asset.filename != "..", files[asset.filename] == nil else {
                    throw WebDAVSyncError.invalidAsset
                }
                progressDetail = "正在恢复：\(title) · \(asset.filename)"
                files[asset.filename] = try await client.downloadBlob(asset.hash)
                completedUnits += 1
            }
            return files
        } catch {
            files.values.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    private func savePassword() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "password"]
        let value = Data(password.utf8)
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        var attributes = query
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }

    private static func readPassword(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "password",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct WebDAVSyncView: View {
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore

    var body: some View {
        Form {
            Section {
                Toggle("启用 WebDAV 同步", isOn: $syncStore.isEnabled)
            } footer: {
                Text("关闭后，书库中的同步操作会停止；已保存的服务器地址和凭据会保留。")
            }
            Section {
                Toggle("书籍同步", isOn: $syncStore.syncBooks)
                Toggle("标签同步", isOn: $syncStore.syncTags)
                Toggle("阅读背景同步", isOn: $syncStore.syncBackgrounds)
                Toggle("导入字体同步", isOn: $syncStore.syncFonts)
            } header: {
                Text("同步内容")
            } footer: {
                Text("书籍同步包含下载文件、阅读进度和书库系列；标签同步包含屏蔽与解除屏蔽记录。背景包含浅深色颜色及竖横屏图片；字体同步仅包含导入的字体文件，请确认字体许可允许同步。可独立开启，关闭的内容会保留在云端，不参与本次同步。")
            }
            .disabled(syncStore.isSyncing)
            Section("服务器") {
                TextField("https://example.com/dav/", text: $syncStore.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $syncStore.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码或应用密码", text: $syncStore.password)
            }
            Section {
                Button {
                    Task { await syncStore.sync(web: webDownloads, wenku: wenkuDownloads) }
                } label: {
                    if syncStore.isSyncing { ProgressView("正在同步…") }
                    else { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncStore.isSyncing || !syncStore.isEnabled)
                if syncStore.isSyncing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(syncStore.completedUnits),
                                     total: Double(syncStore.totalUnits))
                            .tint(.accentColor)
                        Text(syncStore.progressDetail)
                            .font(.footnote)
                            .lineLimit(2)
                        Text("\(syncStore.completedUnits) / \(syncStore.totalUnits) · \(Int(Double(syncStore.completedUnits) / Double(syncStore.totalUnits) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let message = syncStore.message { Text(message).font(.footnote) }
            } footer: {
                Text("使用 HTTPS WebDAV。下载文件、阅读位置和屏蔽标签保存在服务器的 NoveliaSync/v1 文件夹；冲突时按每本书的下载或导入时间保留较新版本。标签按每个标签最后修改时间合并，解除屏蔽也会同步。书目同步为追加与恢复，本地删除不会删除云端副本，下一次同步可能重新恢复该书。请使用可信服务器：同步内容未端到端加密。用户名保存在本机设置，密码保存在钥匙串。")
            }
        }
        .navigationTitle("WebDAV 同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WebDAVSyncProgressPanel: View {
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @Environment(\.dismiss) private var dismiss
    let onCancel: () -> Void
    let onSyncAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .font(.subheadline)
            }
            if syncStore.isSyncing {
                ProgressView(value: Double(syncStore.completedUnits), total: Double(max(syncStore.totalUnits, 1)))
                    .tint(NoveliaStyle.brandGreen)
                Text(syncStore.progressDetail)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(syncStore.completedUnits) / \(syncStore.totalUnits) · \(Int(Double(syncStore.completedUnits) / Double(max(syncStore.totalUnits, 1)) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NoveliaStyle.muted)
                Button(role: .destructive, action: onCancel) {
                    Label("取消同步", systemImage: "xmark.circle")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(syncStore.message ?? syncStore.progressDetail)
                    .font(.subheadline)
                    .foregroundStyle(NoveliaStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onSyncAgain) {
                    Label("再次同步", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(NoveliaStyle.brandGreen)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .environmentObject(syncStore)
    }
}
