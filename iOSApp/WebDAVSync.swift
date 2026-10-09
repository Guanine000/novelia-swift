import CryptoKit
import Foundation
import Security
import SwiftUI

struct SyncedReadingPosition: Codable {
    var chapterIndex: Int?
    var fraction: Double?
    var updatedAt: Date
}

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

    static func recordEPUB(hash: String, fraction: Double) {
        var positions = all()
        positions["epub:\(hash)"] = SyncedReadingPosition(chapterIndex: nil,
            fraction: min(1, max(0, fraction)), updatedAt: Date())
        save(positions)
    }

    static func epubFraction(hash: String) -> Double? { all()["epub:\(hash)"]?.fraction }

    static func merge(_ remote: [String: SyncedReadingPosition], webBooks: [DownloadedWebNovel]) {
        var positions = all()
        let defaults = UserDefaults.standard
        for book in webBooks {
            let key = "web:\(book.id)"
            if positions[key] == nil, defaults.object(forKey: "progress.\(book.id)") != nil {
                positions[key] = SyncedReadingPosition(
                    chapterIndex: defaults.integer(forKey: "progress.\(book.id)"), fraction: nil,
                    updatedAt: defaults.object(forKey: "progressTime.\(book.id)") as? Date ?? .distantPast)
            }
        }
        for (key, value) in remote where value.updatedAt >= (positions[key]?.updatedAt ?? .distantPast) {
            positions[key] = value
        }
        for book in webBooks {
            if let position = positions["web:\(book.id)"], let index = position.chapterIndex {
                defaults.set(index, forKey: "progress.\(book.id)")
                defaults.set(position.updatedAt, forKey: "progressTime.\(book.id)")
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
        case .unexpectedResponse(let status): "WebDAV 请求失败（HTTP \(status)）。请检查地址、账号和服务器权限。"
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
              destination.host == original.host, destination.port == original.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct WebDAVClient {
    let root: URL
    let authorization: String
    private let session = URLSession(configuration: .ephemeral, delegate: WebDAVRedirectGuard(), delegateQueue: nil)

    init(address: String, username: String, password: String) throws {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw WebDAVSyncError.invalidURL }
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

    func prepareFolders() async throws {
        let parent = root.deletingLastPathComponent()
        for folder in [parent, root, root.appendingPathComponent("blobs", isDirectory: true)] {
            let (_, response) = try await session.data(for: request(folder, method: "MKCOL"))
            let code = try status(response)
            guard [201, 405].contains(code) else { throw WebDAVSyncError.unexpectedResponse(code) }
        }
    }

    func fetchManifest() async throws -> (WebDAVManifest, String?, Bool) {
        let (data, response) = try await session.data(for: request(root.appendingPathComponent("index.json"), method: "GET"))
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
        let (_, headResponse) = try await session.data(for: request(url, method: "HEAD"))
        let headCode = try status(headResponse)
        if headCode == 200 { return }
        guard headCode == 404 else { throw WebDAVSyncError.unexpectedResponse(headCode) }
        var put = request(url, method: "PUT")
        put.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await session.upload(for: put, fromFile: file)
        let code = try status(response)
        guard (200...299).contains(code) || code == 412 else { throw WebDAVSyncError.unexpectedResponse(code) }
    }

    func downloadBlob(_ hash: String) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(try blobURL(hash), method: "GET"))
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
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: "webdav.address") } }
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: "webdav.username") } }
    @Published var password: String = ""
    @Published private(set) var isSyncing = false
    @Published var message: String?

    private let keychainService = "cc.novelia.ios.port.webdav"

    init() {
        address = UserDefaults.standard.string(forKey: "webdav.address") ?? ""
        username = UserDefaults.standard.string(forKey: "webdav.username") ?? ""
        password = Self.readPassword(service: keychainService) ?? ""
    }

    func sync(web: WebNovelDownloadStore, wenku: WenkuLocalLibraryStore) async {
        guard !isSyncing else { return }
        isSyncing = true
        message = nil
        defer { isSyncing = false }
        do {
            guard !username.isEmpty, !username.contains(":"), !password.isEmpty else {
                throw WebDAVSyncError.missingCredentials
            }
            try savePassword()
            let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                          username: username, password: password)
            try await client.prepareFolders()
            let (fetchedManifest, etag, existed) = try await client.fetchManifest()
            var manifest = fetchedManifest
            let remoteWeb = manifest.webBooks
            let remoteWenku = manifest.wenkuBooks
            var imported = 0
            for item in remoteWeb where !web.books.contains(where: { $0.id == item.record.id }) {
                let files = try await download(item.assets, with: client)
                defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                try web.restoreFromSync(item.record, files: files)
                imported += 1
            }
            for item in remoteWenku where !wenku.books.contains(where: { $0.id == item.record.id }) {
                let files = try await download(item.assets, with: client)
                defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                try wenku.restoreFromSync(item.record, files: files)
                imported += 1
            }
            ReadingPositionSync.merge(manifest.positions, webBooks: web.books)
            for book in web.books where !manifest.webBooks.contains(where: { $0.record.id == book.id }) {
                let files = web.syncFiles(for: book)
                guard files.count == [book.chapterDataFilename, book.fileFilename].compactMap({ $0 }).count else {
                    throw WebDAVSyncError.invalidAsset
                }
                manifest.webBooks.append(try await remoteBook(book, files: files, client: client))
            }
            for book in wenku.books where !manifest.wenkuBooks.contains(where: { $0.record.id == book.id }) {
                let files = wenku.syncFiles(for: book)
                guard files[book.filename] != nil else { throw WebDAVSyncError.invalidAsset }
                manifest.wenkuBooks.append(try await remoteBook(book, files: files, client: client))
            }
            let webKeys = Set(manifest.webBooks.map { "web:\($0.record.id)" })
            let epubKeys = Set((manifest.webBooks.flatMap(\.assets) + manifest.wenkuBooks.flatMap(\.assets))
                .map { "epub:\($0.hash)" })
            manifest.positions = ReadingPositionSync.all().filter { webKeys.contains($0.key) || epubKeys.contains($0.key) }
            try await client.putManifest(manifest, etag: etag, existed: existed)
            message = "同步完成：恢复 \(imported) 本书，网络小说 \(web.books.count) 本，文库 \(wenku.books.count) 本。"
        } catch {
            message = "同步失败：\(error.localizedDescription)"
        }
    }

    private func remoteBook<Record: Codable>(_ record: Record, files: [String: URL],
                                              client: WebDAVClient) async throws -> WebDAVBook<Record> {
        var assets: [WebDAVAsset] = []
        for (filename, url) in files.sorted(by: { $0.key < $1.key }) {
            let hash = try await Task.detached(priority: .utility) {
                try WebDAVFileHash.sha256(url)
            }.value
            try await client.uploadBlob(url, hash: hash)
            assets.append(WebDAVAsset(filename: filename, hash: hash))
        }
        return WebDAVBook(record: record, assets: assets)
    }

    private func download(_ assets: [WebDAVAsset], with client: WebDAVClient) async throws -> [String: URL] {
        var files: [String: URL] = [:]
        do {
            for asset in assets {
                guard !asset.filename.isEmpty, asset.filename == URL(fileURLWithPath: asset.filename).lastPathComponent,
                      asset.filename != ".", asset.filename != "..", files[asset.filename] == nil else {
                    throw WebDAVSyncError.invalidAsset
                }
                files[asset.filename] = try await client.downloadBlob(asset.hash)
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
                .disabled(syncStore.isSyncing)
                if let message = syncStore.message { Text(message).font(.footnote) }
            } footer: {
                Text("使用 HTTPS WebDAV。下载文件与阅读位置保存在服务器的 NoveliaSync/v1 文件夹；不会删除任一端的书籍。请使用可信服务器：同步内容未端到端加密。用户名保存在本机设置，密码保存在钥匙串。")
            }
        }
        .navigationTitle("WebDAV 同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}
