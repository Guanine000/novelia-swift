// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ReadiumZIPFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 本地整库备份的元信息；保存在压缩包根目录的 `backup-meta.json`。
struct LocalBackupMetadata: Codable, Equatable {
    var version = 1
    let createdAt: Date
    let appVersion: String
    let webBookCount: Int
    let wenkuBookCount: Int
    let blobCount: Int
}

/// 本地整库恢复结果摘要。
struct LocalBackupSummary: Equatable {
    var restoredBooks = 0
    var skippedExistingBooks = 0
    var appliedMetadataBooks = 0
    var mergedPositions = 0
    var mergedBookmarks = 0
    var mergedAnnotations = 0
    var mergedTXTAdjustments = 0
}

enum LocalBackupError: LocalizedError {
    case invalidArchive
    case unsupportedVersion
    case corruptBlob(String)
    case missingBlob(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "备份文件格式无效或已损坏，未修改当前数据。"
        case .unsupportedVersion:
            "此备份由更新版本的 Novelia 生成，当前版本无法读取。"
        case .corruptBlob(let name):
            "备份中的文件「\(name)」校验失败，已中止恢复以保护现有数据。"
        case .missingBlob(let name):
            "备份缺少引用的文件「\(name)」，已中止恢复。"
        case .writeFailed(let reason):
            "创建备份失败：\(reason)"
        }
    }
}

/// 本地整库备份与恢复服务：复用现有同步模型与合并规则，将全部本机书籍、进度、书签、摘录、
/// TXT 手工分章、单书文字处理、系列、标签、背景、字体、人物卡与阅读统计打包为单一 zip，
/// 恢复时按时间戳非破坏性合并。不包含账号凭据、WebDAV 密码与 AI API 密钥。
@MainActor
enum LocalLibraryBackupService {
    private static let maxJSONBytes = 32 * 1024 * 1024

    static func exportBackup(
        web: any SyncBookLibrary<DownloadedWebNovel>,
        wenku: any SyncBookLibrary<LocalWenkuEPUB>,
        local: any WebDAVSyncLocalState,
        statistics: any ReadingStatisticsSyncing,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> URL {
        progress("正在读取本机书库…")
        try await web.prepareForSync()
        try await wenku.prepareForSync()

        var manifest = WebDAVManifest()
        var blobsByHash: [String: URL] = [:]

        progress("正在整理书籍文件…")
        for book in web.books {
            try Task.checkCancellation()
            let assets = try await collectAssets(from: web.syncFiles(for: book), into: &blobsByHash)
            guard !assets.isEmpty else { continue }
            manifest.webBooks.append(WebDAVBook(record: book, assets: assets))
        }
        for book in wenku.books {
            try Task.checkCancellation()
            let assets = try await collectAssets(from: wenku.syncFiles(for: book), into: &blobsByHash)
            guard !assets.isEmpty else { continue }
            manifest.wenkuBooks.append(WebDAVBook(record: book, assets: assets))
        }

        progress("正在收集阅读进度与偏好…")
        manifest.positions = local.readingPositions
        manifest.librarySeries = local.librarySeries
        manifest.bookmarks = local.bookmarks
        manifest.textProjections = local.textProjections
        manifest.annotations = local.annotations
        manifest.txtChapterAdjustments = local.txtChapterAdjustments
        manifest.blockedTags = local.blockedTags

        var backgrounds: [String: SyncedReaderBackground] = [:]
        for dark in [false, true] {
            if let snapshot = try? local.background(dark: dark) {
                backgrounds[dark ? "dark" : "light"] = snapshot
                for landscape in [false, true] {
                    let url = local.backgroundImageURL(dark: dark, landscape: landscape)
                    if FileManager.default.fileExists(atPath: url.path),
                       let hash = try? await hashFile(url) {
                        blobsByHash[hash] = url
                    }
                }
            }
        }
        if !backgrounds.isEmpty { manifest.backgrounds = backgrounds }

        if let fonts = try? local.fonts(), !fonts.isEmpty {
            manifest.fonts = fonts
            if let files = try? local.fontFiles() {
                for (hash, url) in files where WebDAVAsset.isValidHash(hash) && FileManager.default.fileExists(atPath: url.path) {
                    blobsByHash[hash] = url
                }
            }
        }

        let webEPUBMaps = local.webEPUBMaps
        let characters = try local.characterSync?.characterSnapshot()
        if let characters, let characterSync = local.characterSync {
            for hash in characters.portraitHashes {
                if let file = characterSync.portraitFile(hash), FileManager.default.fileExists(atPath: file.path) {
                    blobsByHash[hash] = file
                }
            }
        }
        let statsSnapshot = statistics.syncSnapshot()

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let meta = LocalBackupMetadata(
            createdAt: Date(),
            appVersion: appVersion,
            webBookCount: manifest.webBooks.count,
            wenkuBookCount: manifest.wenkuBooks.count,
            blobCount: blobsByHash.count
        )

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let stamp = Self.filenameTimestamp(meta.createdAt)
        let archiveURL = base.appendingPathComponent("NoveliaBackup-\(stamp).zip")
        try? FileManager.default.removeItem(at: archiveURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        progress("正在打包压缩文件…")
        do {
            let archive = try await Archive(url: archiveURL, accessMode: .create)
            try await addJSON(meta, named: "backup-meta.json", to: archive, encoder: encoder)
            try await addJSON(manifest, named: "manifest.json", to: archive, encoder: encoder)
            if !statsSnapshot.devices.isEmpty {
                try await addJSON(statsSnapshot, named: "statistics.json", to: archive, encoder: encoder)
            }
            if !webEPUBMaps.isEmpty {
                try await addJSON(webEPUBMaps, named: "web-epub-maps.json", to: archive, encoder: encoder)
            }
            if let characters {
                try await addJSON(characters, named: "characters.json", to: archive, encoder: encoder)
            }
            let sortedBlobs = blobsByHash.sorted { $0.key < $1.key }
            for (index, item) in sortedBlobs.enumerated() {
                try Task.checkCancellation()
                progress("正在写入文件（\(index + 1)/\(sortedBlobs.count)）…")
                let ext = item.value.pathExtension.lowercased()
                let method: CompressionMethod = ["epub", "jpg", "jpeg", "png", "webp", "zip"].contains(ext) ? .none : .deflate
                try await archive.addEntry(with: "blobs/\(item.key)", fileURL: item.value, compressionMethod: method)
            }
            return archiveURL
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            if error is CancellationError { throw error }
            throw LocalBackupError.writeFailed(error.localizedDescription)
        }
    }

    static func restoreBackup(
        from archiveURL: URL,
        web: any SyncBookLibrary<DownloadedWebNovel>,
        wenku: any SyncBookLibrary<LocalWenkuEPUB>,
        local: any WebDAVSyncLocalState,
        statistics: any ReadingStatisticsSyncing,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> LocalBackupSummary {
        progress("正在准备本机书库…")
        try await web.prepareForSync()
        try await wenku.prepareForSync()

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoveliaRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        progress("正在读取并校验备份包…")
        let archive: Archive
        do {
            archive = try await Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LocalBackupError.invalidArchive
        }

        let metaData = try await readEntry(named: "backup-meta.json", from: archive)
        let meta: LocalBackupMetadata
        do {
            meta = try JSONDecoder().decode(LocalBackupMetadata.self, from: metaData)
        } catch {
            throw LocalBackupError.invalidArchive
        }
        guard meta.version == 1 else { throw LocalBackupError.unsupportedVersion }

        let manifestData = try await readEntry(named: "manifest.json", from: archive)
        let manifest: WebDAVManifest
        do {
            manifest = try JSONDecoder().decode(WebDAVManifest.self, from: manifestData)
        } catch {
            throw LocalBackupError.invalidArchive
        }
        guard manifest.version == 1 else { throw LocalBackupError.unsupportedVersion }

        let statsSnapshot: ReadingStatisticsSync? = try await readOptionalJSON(named: "statistics.json", from: archive)
        let webEPUBMaps: [String: WebNovelEPUBMap]? = try await readOptionalJSON(named: "web-epub-maps.json", from: archive)
        let characters: CharacterSyncState? = try await readOptionalJSON(named: "characters.json", from: archive)

        var extractedBlobs: [String: URL] = [:]
        func ensureBlob(_ hash: String, displayName: String) async throws -> URL {
            guard WebDAVAsset.isValidHash(hash) else { throw LocalBackupError.corruptBlob(displayName) }
            if let existing = extractedBlobs[hash] { return existing }
            guard let entry = try? await archive.get("blobs/\(hash)") else { throw LocalBackupError.missingBlob(displayName) }
            let destination = staging.appendingPathComponent(hash)
            _ = try await archive.extract(entry, to: destination)
            let actual = try await hashFile(destination)
            guard actual == hash else {
                try? FileManager.default.removeItem(at: destination)
                throw LocalBackupError.corruptBlob(displayName)
            }
            extractedBlobs[hash] = destination
            return destination
        }

        var summary = LocalBackupSummary()

        // 1. 恢复缺失的网络小说与文库书籍；已存在的同版本文库书合并较新的编辑信息。
        let existingWebIDs = Set(web.books.map(\.id))
        for item in manifest.webBooks {
            try Task.checkCancellation()
            if existingWebIDs.contains(item.record.id) {
                summary.skippedExistingBooks += 1
                continue
            }
            progress("正在恢复网络小说：\(item.record.novel.title)")
            var files: [String: URL] = [:]
            for asset in item.assets {
                guard WebDAVAsset.isSafeFilename(asset.filename) else { throw LocalBackupError.invalidArchive }
                files[asset.filename] = try await ensureBlob(asset.hash, displayName: asset.filename)
            }
            try await web.restoreFromSync(item.record, files: files)
            summary.restoredBooks += 1
        }

        let existingWenkuByID = Dictionary(uniqueKeysWithValues: wenku.books.map { ($0.id, $0) })
        for item in manifest.wenkuBooks {
            try Task.checkCancellation()
            if let localBook = existingWenkuByID[item.record.id] {
                if localBook.syncTimestamp == item.record.syncTimestamp,
                   let remoteAt = item.record.metadataUpdatedAt,
                   remoteAt > (localBook.metadataUpdatedAt ?? .distantPast) {
                    var coverURL: URL?
                    if let coverName = item.record.coverFilename,
                       let coverAsset = item.assets.first(where: { $0.filename == coverName }),
                       WebDAVAsset.isSafeFilename(coverAsset.filename) {
                        coverURL = try? await ensureBlob(coverAsset.hash, displayName: coverName)
                    }
                    try await wenku.applySyncedMetadata(item.record, cover: coverURL)
                    summary.appliedMetadataBooks += 1
                } else {
                    summary.skippedExistingBooks += 1
                }
                continue
            }
            progress("正在恢复书库书籍：\(item.record.title)")
            var files: [String: URL] = [:]
            for asset in item.assets {
                guard WebDAVAsset.isSafeFilename(asset.filename) else { throw LocalBackupError.invalidArchive }
                files[asset.filename] = try await ensureBlob(asset.hash, displayName: asset.filename)
            }
            try await wenku.restoreFromSync(item.record, files: files)
            summary.restoredBooks += 1
        }

        // 2. 合并阅读进度、系列、书签、摘录、文字处理、TXT 分章与标签。
        progress("正在合并阅读进度与书签…")
        if !manifest.positions.isEmpty {
            local.mergeReadingPositions(manifest.positions, webBooks: web.books)
            summary.mergedPositions = manifest.positions.count
        }
        if let series = manifest.librarySeries {
            local.applyLibrarySeries(LibrarySeriesState.merged(local.librarySeries, series))
        }
        if let bookmarks = manifest.bookmarks, !bookmarks.isEmpty {
            try local.applyBookmarks(ReaderBookmark.merged(local.bookmarks, bookmarks))
            summary.mergedBookmarks = bookmarks.count
        }
        if let projections = manifest.textProjections, !projections.isEmpty {
            local.applyTextProjections(ReaderTextProjectionRecord.merged(local.textProjections, projections))
        }
        if let annotations = manifest.annotations, !annotations.isEmpty {
            try local.applyAnnotations(ReaderAnnotation.mergedSync(local.annotations, annotations))
            summary.mergedAnnotations = annotations.count
        }
        if let txtAdjustments = manifest.txtChapterAdjustments, !txtAdjustments.isEmpty {
            try await local.applyTXTChapterAdjustments(SyncedTXTChapterAdjustment.merged(local.txtChapterAdjustments, txtAdjustments))
            summary.mergedTXTAdjustments = txtAdjustments.count
        }
        if let blockedTags = manifest.blockedTags {
            local.applyBlockedTags(BlockedTagsStore.merged(local.blockedTags, blockedTags))
        }

        // 3. 合并阅读背景与导入字体。
        progress("正在恢复背景与字体…")
        if let backgrounds = manifest.backgrounds {
            for dark in [false, true] {
                let key = dark ? "dark" : "light"
                guard let remote = backgrounds[key],
                      let current = try? local.background(dark: dark),
                      remote.updatedAt > current.updatedAt else { continue }
                var files: [String: URL] = [:]
                for hash in [remote.portraitHash, remote.landscapeHash].compactMap({ $0 }) {
                    let url = try await ensureBlob(hash, displayName: "background-\(key)")
                    guard local.isValidBackgroundImage(url) else { throw LocalBackupError.corruptBlob("background-\(key)") }
                    files[hash] = url
                }
                try local.applyBackground(remote, dark: dark, files: files)
            }
        }
        if let remoteFonts = manifest.fonts, !remoteFonts.isEmpty,
           let localFonts = try? local.fonts(),
           let localFontFiles = try? local.fontFiles() {
            let mergedFonts = SyncedImportedFont.merged(localFonts, remoteFonts)
            var downloadedFonts: [String: URL] = [:]
            for (hash, record) in mergedFonts where !record.deleted && localFontFiles[hash] == nil {
                guard WebDAVAsset.isValidHash(hash) else { continue }
                if let url = try? await ensureBlob(hash, displayName: "\(record.hash.prefix(8)).\(record.format)") {
                    downloadedFonts[hash] = url
                }
            }
            try local.applyFonts(mergedFonts, files: downloadedFonts)
        }

        // 4. 合并网络小说章节映射、人物卡与阅读统计。
        if let maps = webEPUBMaps, !maps.isEmpty {
            try local.applyWebEPUBMaps(maps)
        }
        if let remoteChars = characters, let characterSync = local.characterSync {
            let validated = try remoteChars.validated()
            let current = try characterSync.characterSnapshot()
            let merged = try CharacterSyncState.merged(current, validated)
            for hash in merged.portraitHashes where characterSync.portraitFile(hash) == nil {
                if let file = try? await ensureBlob(hash, displayName: "portrait-\(hash.prefix(8))"),
                   let data = try? Data(contentsOf: file) {
                    try? characterSync.installPortrait(data, hash: hash)
                }
            }
            try characterSync.applyCharacters(merged)
        }
        if let remoteStats = statsSnapshot, remoteStats.isValid {
            let merged = ReadingStatisticsSync.merged(statistics.syncSnapshot(), remoteStats)
            statistics.applySynced(merged)
        }

        return summary
    }

    private static func collectAssets(from files: [String: URL], into blobs: inout [String: URL]) async throws -> [WebDAVAsset] {
        var assets: [WebDAVAsset] = []
        for (filename, url) in files.sorted(by: { $0.key < $1.key }) {
            guard WebDAVAsset.isSafeFilename(filename),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let hash = try await hashFile(url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            blobs[hash] = url
            assets.append(WebDAVAsset(filename: filename, hash: hash, size: size))
        }
        return assets
    }

    private static func hashFile(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try FileContentHash.sha256(url)
        }.value
    }

    private static func addJSON<Value: Encodable>(_ value: Value, named name: String, to archive: Archive, encoder: JSONEncoder) async throws {
        let data = try encoder.encode(value)
        try await archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func readEntry(named name: String, from archive: Archive) async throws -> Data {
        guard let entry = try? await archive.get(name) else { throw LocalBackupError.invalidArchive }
        guard entry.uncompressedSize <= maxJSONBytes else { throw LocalBackupError.invalidArchive }
        var buffer = Data()
        _ = try await archive.extract(entry) { chunk in
            guard buffer.count + chunk.count <= maxJSONBytes else { throw LocalBackupError.invalidArchive }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func readOptionalJSON<Value: Decodable>(named name: String, from archive: Archive) async throws -> Value? {
        guard (try? await archive.get(name)) != nil else { return nil }
        let data = try await readEntry(named: name, from: archive)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LocalBackupError.invalidArchive
        }
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// “我的 → 同步 → 本地备份与恢复”页面。
struct LocalBackupView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuLibrary: WenkuLocalLibraryStore

    @State private var isBusy = false
    @State private var statusText = ""
    @State private var errorMessage: String?
    @State private var summaryMessage: String?
    @State private var exportedShare: LibraryArchiveShare?
    @State private var showsImporter = false

    var body: some View {
        Form {
            Section {
                Button {
                    startExport()
                } label: {
                    Label(isBusy ? "正在处理…" : "导出整库备份", systemImage: "square.and.arrow.up")
                }
                .disabled(isBusy)

                Button {
                    showsImporter = true
                } label: {
                    Label("从本地备份恢复", systemImage: "square.and.arrow.down")
                }
                .disabled(isBusy)
            } header: {
                Text("操作")
            } footer: {
                Text("备份包含本机书籍文件、阅读进度、书签、摘录与笔记、TXT 手工分章、单书文字处理、系列、标签屏蔽、阅读背景、导入字体、人物卡与阅读统计；不包含账号凭据、WebDAV 密码和 AI 密钥。")
            }

            if isBusy {
                Section("进度") {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(statusText.isEmpty ? "正在处理…" : statusText)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summaryMessage {
                Section("结果") {
                    Text(summaryMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section("错误") {
                    Text(errorMessage)
                        .foregroundStyle(NoveliaStyle.danger)
                }
            }

            Section {
                Text("恢复采用非破坏性合并：缺失的书籍会被恢复到书库，已存在的书籍不会覆盖；进度、书签、摘录、分章和系列按较新的修改时间合并，阅读统计按设备取最大值。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明")
            }
        }
        .navigationTitle("本地备份与恢复")
        .sheet(item: $exportedShare, onDismiss: {
            if let url = exportedShare?.url { try? FileManager.default.removeItem(at: url) }
        }) { share in
            LibraryArchiveShareSheet(url: share.url)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                startRestore(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startExport() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        summaryMessage = nil
        statusText = "正在准备导出…"
        Task { @MainActor in
            defer { isBusy = false }
            do {
                let url = try await LocalLibraryBackupService.exportBackup(
                    web: webDownloads,
                    wenku: wenkuLibrary,
                    local: services.local.syncLocalState,
                    statistics: services.local.statistics
                ) { stage in
                    statusText = stage
                }
                exportedShare = LibraryArchiveShare(url: url, title: url.lastPathComponent)
                summaryMessage = "已生成备份包：\(url.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startRestore(from url: URL) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        summaryMessage = nil
        statusText = "正在打开备份文件…"
        Task { @MainActor in
            defer { isBusy = false }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await LocalLibraryBackupService.restoreBackup(
                    from: url,
                    web: webDownloads,
                    wenku: wenkuLibrary,
                    local: services.local.syncLocalState,
                    statistics: services.local.statistics
                ) { stage in
                    statusText = stage
                }
                var parts: [String] = []
                parts.append("恢复书籍 \(summary.restoredBooks) 本")
                if summary.skippedExistingBooks > 0 { parts.append("保留已有 \(summary.skippedExistingBooks) 本") }
                if summary.appliedMetadataBooks > 0 { parts.append("更新书库信息 \(summary.appliedMetadataBooks) 本") }
                if summary.mergedPositions > 0 { parts.append("合并进度 \(summary.mergedPositions) 项") }
                if summary.mergedBookmarks > 0 { parts.append("合并书签 \(summary.mergedBookmarks) 条") }
                if summary.mergedAnnotations > 0 { parts.append("合并摘录 \(summary.mergedAnnotations) 条") }
                if summary.mergedTXTAdjustments > 0 { parts.append("合并 TXT 分章 \(summary.mergedTXTAdjustments) 本") }
                summaryMessage = "恢复完成：" + parts.joined(separator: "，") + "。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
