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
                let webPlan = WebDAVSyncPlanner.planBooks(local: web.books, remote: manifest.webBooks)
                let wenkuPlan = WebDAVSyncPlanner.planBooks(local: wenku.books, remote: manifest.wenkuBooks)
                totalUnits = webPlan.unitCount { web.syncFiles(for: $0).count }
                    + wenkuPlan.unitCount { wenku.syncFiles(for: $0).count }
                    + 1
                stage = "恢复远端下载"
                for item in webPlan.downloads {
                    try Task.checkCancellation()
                    let record = item.book.record
                    let files = try await download(item.book.assets, title: record.novel.title, with: client)
                    defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                    if item.replacesLocal {
                        try web.replaceFromSync(record, files: files)
                    } else {
                        try web.restoreFromSync(record, files: files)
                        imported += 1
                    }
                }
                for item in wenkuPlan.downloads {
                    try Task.checkCancellation()
                    let record = item.book.record
                    let files = try await download(item.book.assets, title: record.title, with: client)
                    defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
                    if item.replacesLocal {
                        try wenku.replaceFromSync(record, files: files)
                    } else {
                        try wenku.restoreFromSync(record, files: files)
                        imported += 1
                    }
                }
                ReadingPositionSync.merge(manifest.positions, webBooks: web.books)
                stage = "上传本地下载"
                for book in webPlan.uploads {
                    try Task.checkCancellation()
                    let files = web.syncFiles(for: book)
                    guard files.count == 1 else {
                        throw WebDAVSyncError.invalidAsset
                    }
                    manifest.webBooks.upsert(try await remoteBook(book, title: book.novel.title, files: files, client: client))
                }
                for book in wenkuPlan.uploads {
                    try Task.checkCancellation()
                    let files = wenku.syncFiles(for: book)
                    guard files[book.filename] != nil else { throw WebDAVSyncError.invalidAsset }
                    manifest.wenkuBooks.upsert(try await remoteBook(book, title: book.title, files: files, client: client))
                }
                manifest.positions = WebDAVSyncPlanner.positionsToSync(ReadingPositionSync.all(), in: manifest)
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
                    switch WebDAVSyncPlanner.planBackground(local: local, remote: backgrounds[key]) {
                    case .useRemote(let hashes):
                        for hash in hashes {
                            let file = try await client.downloadBlob(hash)
                            temporaryFiles.append(file)
                            guard UIImage(contentsOfFile: file.path) != nil else { throw WebDAVSyncError.invalidAsset }
                            resourceFiles[hash] = file
                        }
                    case .useLocal:
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
                let plan = try WebDAVSyncPlanner.planFonts(fonts, localHashes: Set(files.keys))
                for hash in plan.uploads {
                    if let file = files[hash] { try await client.uploadBlob(file, hash: hash) }
                }
                for hash in plan.downloads {
                    let file = try await client.downloadBlob(hash); temporaryFiles.append(file); resourceFiles[hash] = file
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
                                              client: any WebDAVRemote) async throws -> WebDAVBook<Record> {
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
                          with client: any WebDAVRemote) async throws -> [String: URL] {
        var files: [String: URL] = [:]
        do {
            for asset in assets {
                try Task.checkCancellation()
                guard WebDAVAsset.isSafeFilename(asset.filename), files[asset.filename] == nil else {
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
