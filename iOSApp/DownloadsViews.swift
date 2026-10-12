import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

enum MyDownloadsTab: String, CaseIterable, Identifiable {
    case network, wenku
    var id: String { rawValue }
    var title: String { self == .network ? "网络小说" : "文库" }
}

private enum MyDownloadsImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "只支持导入 .txt 或 .epub 文件。"
    }
}

struct MyDownloadsView: View {
    @EnvironmentObject private var webNovelDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var webDAVSync: WebDAVSyncStore
    @StateObject private var txtChapterRuleStore = TXTChapterRuleStore.shared
    @State private var selectedTab: MyDownloadsTab
    @State private var prototypeTarget: EPUBDownloadTarget?
    @State private var txtReaderTarget: DownloadedWebNovel?
    @State private var wenkuTXTTarget: LocalWenkuEPUB?
    @State private var moveError: String?
    @State private var isShowingFileImporter = false
    @State private var isImporting = false
    @State private var importCompletedCount = 0
    @State private var importTotalCount = 0
    @State private var importError: String?
    @State private var syncTask: Task<Void, Never>?
    @State private var hasTriggeredSync = false
    @State private var isShowingSyncProgress = false

    init(initialTab: MyDownloadsTab = .network) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("下载内容", selection: $selectedTab) {
                ForEach(MyDownloadsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Group {
                switch selectedTab {
                case .network: networkDownloads
                case .wenku: wenkuDownloadsList
                }
            }
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("我的下载")
        .navigationBarTitleDisplayMode(.inline)
        .task { await wenkuDownloads.refreshMissingMetadata() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        if hasTriggeredSync || webDAVSync.isSyncing {
                            isShowingSyncProgress = true
                        } else {
                            hasTriggeredSync = true
                            syncTask = Task {
                                await webDAVSync.sync(web: webNovelDownloads, wenku: wenkuDownloads)
                            }
                        }
                    } label: {
                        if webDAVSync.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .accessibilityLabel(webDAVSync.isSyncing ? "查看同步进度" : "WebDAV 同步")
                    .disabled(!webDAVSync.isEnabled)

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("导入 TXT / EPUB", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入 TXT 或 EPUB")
                }
            }
        }
        .sheet(isPresented: $isShowingSyncProgress) {
            WebDAVSyncProgressPanel(onCancel: { syncTask?.cancel() }) {
                syncTask = Task { await webDAVSync.sync(web: webNovelDownloads, wenku: wenkuDownloads) }
            }
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: webDAVSync.isEnabled) { _, isEnabled in
            if !isEnabled { syncTask?.cancel() }
        }
        .navigationDestination(item: $prototypeTarget) { target in
            EPUBReaderHost(initialURL: target.url)
        }
        .navigationDestination(item: $txtReaderTarget) { book in
            DownloadedWebNovelTXTReader(url: webNovelDownloads.fileURL(for: book), title: book.novel.title, rules: txtChapterRuleStore.configuration)
        }
        .navigationDestination(item: $wenkuTXTTarget) { book in
            DownloadedWebNovelTXTReader(url: wenkuDownloads.fileURL(for: book), title: book.title, rules: txtChapterRuleStore.configuration)
        }
        .fullScreenCover(isPresented: $isShowingFileImporter) {
            EPUBFilePicker(contentTypes: [
                UTType(filenameExtension: "txt") ?? .plainText,
                UTType(filenameExtension: "epub") ?? .data
            ], allowsMultipleSelection: true) { urls in
                Task { await importFiles(urls) }
            }
            .ignoresSafeArea()
        }
        .alert("导入", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("移动失败", isPresented: .init(
            get: { moveError != nil }, set: { if !$0 { moveError = nil } }
        )) {
            Button("好", role: .cancel) { moveError = nil }
        } message: { Text(moveError ?? "") }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("正在导入书籍", systemImage: "books.vertical")
                            .font(.system(size: 16, weight: .semibold))
                        ProgressView(value: Double(importCompletedCount), total: Double(max(importTotalCount, 1)))
                            .tint(NoveliaStyle.brandGreen)
                        Text("已处理 \(importCompletedCount) / \(importTotalCount) 个文件")
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    .padding(20)
                    .frame(width: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.45), lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
                }
                .transition(.opacity)
            }
        }
    }

    /// 从 Files 批量导入：逐项复制并登记到本地书库，完成后留在列表页。
    private func importFiles(_ pickedURLs: [URL]) async {
        guard !pickedURLs.isEmpty else { return }
        isImporting = true
        importCompletedCount = 0
        importTotalCount = pickedURLs.count
        defer { isImporting = false }

        var failures: [String] = []
        for (index, pickedURL) in pickedURLs.enumerated() {
            do {
                try await importFile(pickedURL)
            } catch {
                failures.append("\(pickedURL.lastPathComponent)：\(error.localizedDescription)")
            }
            importCompletedCount = index + 1
        }

        if pickedURLs.count > failures.count {
            selectedTab = .wenku
        }
        if !failures.isEmpty {
            let succeeded = pickedURLs.count - failures.count
            importError = "批量导入完成：成功 \(succeeded) 个，失败 \(failures.count) 个。\n" + failures.joined(separator: "\n")
        }
    }

    private func importFile(_ pickedURL: URL) async throws {
        let extensionName = pickedURL.pathExtension.lowercased()
        let start = ContinuousClock.now
        if extensionName == "txt" {
            TXTDiagnosticLog.logger.info("TXT import started")
        } else if extensionName == "epub" {
            epubImportLog.info("EPUB import started")
        }
        guard extensionName == "txt" || extensionName == "epub" else {
            throw MyDownloadsImportError.unsupportedFile
        }
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
        let destination = wenkuDownloads.downloadDestination(for: pickedURL.lastPathComponent)
        var coordinatedError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: pickedURL, options: .forUploading,
                                       error: &coordinatedError) { sourceURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinatedError ?? copyError {
            if extensionName == "epub" { logEPUBImportFailure(error, stage: "copy", start: start) }
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import copy failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        let title = pickedURL.deletingPathExtension().lastPathComponent
        do {
            try await wenkuDownloads.registerDownloadedFile(at: destination, title: title)
        } catch {
            if extensionName == "epub" { logEPUBImportFailure(error, stage: "registration", start: start) }
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import registration failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        if extensionName == "txt" {
            TXTDiagnosticLog.logger.info("TXT import completed")
        } else {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            epubImportLog.info("EPUB import completed; bytes=\(bytes, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
        }
    }

    private func logEPUBImportFailure(_ error: Error, stage: String, start: ContinuousClock.Instant) {
        let nsError = error as NSError
        let domain = ShareableLogPolicy.domainLabel(nsError.domain)
        epubImportLog.error("EPUB import failed; stage=\(stage, privacy: .public), domain=\(domain, privacy: .public), code=\(nsError.code, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private var networkDownloads: some View {
        Group {
            if webNovelDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无网络小说下载", systemImage: "arrow.down.book")
                } description: {
                    Text("网络小说 EPUB 下载和导入的 TXT 文件会显示在这里，可阅读或导出。")
                }
            } else {
                List {
                    ForEach(webNovelDownloads.books) { book in
                        Button {
                            if book.resolvedFileFormat == .txt {
                                txtReaderTarget = book
                            } else {
                                prototypeTarget = EPUBDownloadTarget(url: webNovelDownloads.fileURL(for: book), title: book.novel.title)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                networkDownloadRow(book)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(NoveliaStyle.card)
                        .swipeActions {
                            Button {
                                Task { await moveToWenku(book) }
                            } label: {
                                Label("移至文库", systemImage: "arrow.right.arrow.left")
                            }
                            .tint(.orange)
                            ShareLink(item: webNovelDownloads.fileURL(for: book)) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                            Button(role: .destructive) {
                                webNovelDownloads.remove(book)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func networkDownloadRow(_ book: DownloadedWebNovel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(book.novel.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(2)
            Text(book.novel.author)
                .font(.system(size: 12))
                .foregroundStyle(NoveliaStyle.muted)
                .lineLimit(1)
            if book.resolvedDownloadMode == .original {
                Text("原文")
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted)
            } else {
                Text("\(book.resolvedDownloadMode.title) · 译源：\(book.translationSource?.title ?? "未知")")
                    .font(.system(size: 11))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            HStack {
                Text("\(book.resolvedFileFormat.title) · \(book.novel.chapters.count) 章 · \(book.downloadedAt.formatted(date: .numeric, time: .omitted))")
                Spacer()
                Image(systemName: "square.and.arrow.up")
            }
            .font(.system(size: 11))
            .foregroundStyle(NoveliaStyle.muted)
        }
        .padding(.vertical, 5)
    }

    private var wenkuDownloadsList: some View {
        Group {
            if wenkuDownloads.books.isEmpty {
                ContentUnavailableView {
                    Label("暂无本地书籍", systemImage: "book.closed")
                } description: {
                    Text("导入 TXT 或 EPUB 后，可在这里阅读、导出或管理本地书籍。")
                }
            } else {
                List {
                    ForEach(wenkuDownloads.books) { book in
                        HStack(spacing: 12) {
                            Button {
                                if book.resolvedFileFormat == .txt {
                                    wenkuTXTTarget = book
                                } else {
                                    prototypeTarget = EPUBDownloadTarget(
                                        url: wenkuDownloads.fileURL(for: book), title: book.title
                                    )
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if let coverURL = wenkuDownloads.coverURL(for: book),
                                       let image = UIImage(contentsOfFile: coverURL.path) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 52, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                    } else {
                                        Image(systemName: "book.closed.fill")
                                            .font(.title2).foregroundStyle(NoveliaStyle.brandGreen)
                                            .frame(width: 52, height: 72)
                                            .background(NoveliaStyle.brandGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                        Text(book.resolvedFileFormat.title)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(NoveliaStyle.brandGreen)
                                        if let author = book.author, !author.isEmpty {
                                            Text(author).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(1)
                                        }
                                        if let description = book.bookDescription, !description.isEmpty {
                                            Text(description).font(.system(size: 11)).foregroundStyle(NoveliaStyle.muted).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: wenkuDownloads.fileURL(for: book)) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(NoveliaStyle.card)
                        .swipeActions {
                            Button {
                                moveToNetwork(book)
                            } label: {
                                Label("移至网络小说", systemImage: "arrow.right.arrow.left")
                            }
                            .tint(.orange)
                            ShareLink(item: wenkuDownloads.fileURL(for: book)) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                            Button(role: .destructive) { wenkuDownloads.remove(book) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func moveToWenku(_ book: DownloadedWebNovel) async {
        do {
            let created = try await wenkuDownloads.importForMove(from: webNovelDownloads.fileURL(for: book), sourceBook: book)
            do { try webNovelDownloads.removeForMove(book) }
            catch { wenkuDownloads.remove(created); throw error }
        } catch { moveError = error.localizedDescription }
    }

    private func moveToNetwork(_ book: LocalWenkuEPUB) {
        do {
            let created = try webNovelDownloads.importForMove(from: wenkuDownloads.fileURL(for: book), book: book)
            do { try wenkuDownloads.removeForMove(book) }
            catch { webNovelDownloads.remove(created); throw error }
        } catch { moveError = error.localizedDescription }
    }
}

// MARK: - EPUB 阅读器导航目标

/// 从“我的下载”推入 EPUB 阅读器的目标书；url 为 nil 时（仅 Debug）使用样例书。
struct EPUBDownloadTarget: Identifiable, Hashable {
    let id = UUID()
    let url: URL?
    let title: String
}

private let epubImportLog = Logger(subsystem: "cc.novelia.ios.port", category: "epub")
