import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

private enum LibraryImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "只支持导入 .txt 或 .epub 文件。"
    }
}

/// 书库的 TXT / EPUB 导入：复制文件、登记到文库书目并记录诊断日志。
@MainActor
final class LibraryImportModel: ObservableObject {
    @Published var isShowingFileImporter = false
    @Published private(set) var isImporting = false
    @Published private(set) var importCompletedCount = 0
    @Published private(set) var importTotalCount = 0
    @Published var importError: String?

    private var library: WenkuLocalLibraryStore!

    func attach(_ library: WenkuLocalLibraryStore) {
        self.library = library
    }

    /// 从“文件”批量导入：逐项复制并登记到本地书库。
    func importFiles(_ pickedURLs: [URL]) async {
        // 一次只执行一个导入：复制期间再次收到选择器回调会重复登记相同文件。
        guard !pickedURLs.isEmpty, !isImporting else { return }
        isImporting = true
        importCompletedCount = 0
        importTotalCount = pickedURLs.count
        defer { isImporting = false }

        var failures: [String] = []
        var duplicates: [String] = []
        // 同一批次重复选择的文件只导入一次。
        var seenPaths = Set<String>()
        for (index, pickedURL) in pickedURLs.enumerated() {
            defer { importCompletedCount = index + 1 }
            guard seenPaths.insert(pickedURL.standardizedFileURL.path).inserted else { continue }
            do {
                try await importFile(pickedURL)
            } catch let duplicate as LocalLibraryDuplicateError {
                duplicates.append("\(pickedURL.lastPathComponent)：已存在（《\(duplicate.existingTitle)》）")
            } catch {
                failures.append("\(pickedURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        let succeeded = seenPaths.count - failures.count - duplicates.count
        if !failures.isEmpty || !duplicates.isEmpty {
            var summary = "批量导入完成：成功 \(succeeded) 个"
            if !duplicates.isEmpty { summary += "，已存在 \(duplicates.count) 个" }
            if !failures.isEmpty { summary += "，失败 \(failures.count) 个" }
            importError = summary + "。\n" + (duplicates + failures).joined(separator: "\n")
        }
    }

    private func importFile(_ pickedURL: URL) async throws {
        try await library.loadIfNeeded()
        let extensionName = pickedURL.pathExtension.lowercased()
        let start = ContinuousClock.now
        let trace = DiagnosticContext.newTraceID()
        if extensionName == "txt" {
            TXTDiagnosticLog.logger.info("TXT import started; trace=\(trace, privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        } else if extensionName == "epub" {
            epubImportLog.info("EPUB import started")
        }
        guard extensionName == "txt" || extensionName == "epub" else {
            throw LibraryImportError.unsupportedFile
        }
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
        let destination = library.downloadDestination(for: pickedURL.lastPathComponent)
        // 先在主线程占住文件名：复制期间同目录的文库下载不会选到同一个目标。
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        // 协调读取可能需要先从 iCloud 下载，大文件复制也很耗时，都放到主线程之外，进度浮窗保持更新。
        let copyResult = await Task.detached(priority: .userInitiated) {
            Result { try Self.coordinatedCopy(from: pickedURL, to: destination) }
        }.value
        if case .failure(let error) = copyResult {
            try? FileManager.default.removeItem(at: destination)
            if extensionName == "epub" { logEPUBImportFailure(error, stage: "copy", start: start) }
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import copy failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        let title = pickedURL.deletingPathExtension().lastPathComponent
        do {
            try await library.registerDownloadedFile(at: destination, title: title, source: .import, trace: trace)
        } catch let duplicate as LocalLibraryDuplicateError {
            if extensionName == "txt" {
                TXTDiagnosticLog.logger.info("TXT import skipped duplicate; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(duplicate.contentHash), privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
            }
            throw duplicate
        } catch {
            if extensionName == "epub" { logEPUBImportFailure(error, stage: "registration", start: start) }
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import registration failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        if extensionName == "txt" {
            let hash = (try? await TXTBookCache.shared.contentHash(of: destination)) ?? ""
            TXTDiagnosticLog.logger.info("TXT import completed; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(hash), privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        } else {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            epubImportLog.info("EPUB import completed; bytes=\(bytes, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
        }
    }

    nonisolated private static func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinatedError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading,
                                       error: &coordinatedError) { sourceURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch { copyError = error }
        }
        if let error = coordinatedError ?? copyError { throw error }
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
}

/// 导入进度浮窗。
struct LibraryImportProgressOverlay: View {
    @ObservedObject var model: LibraryImportModel

    var body: some View {
        if model.isImporting {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Label("正在导入书籍", systemImage: "books.vertical")
                        .font(.system(size: 16, weight: .semibold))
                    ProgressView(value: Double(model.importCompletedCount), total: Double(max(model.importTotalCount, 1)))
                        .tint(NoveliaStyle.brandGreen)
                    Text("已处理 \(model.importCompletedCount) / \(model.importTotalCount) 个文件")
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

/// 在“网络小说/文库”两个下载库之间移动书籍；系列归属与最近打开时间随新标识转移。
@MainActor
enum LibraryMover {
    static func moveToWenku(_ book: DownloadedWebNovel, web: WebNovelDownloadStore,
                            wenku: WenkuLocalLibraryStore, state: LibraryStateStore) async throws {
        try await web.loadIfNeeded()
        guard web.books.contains(book) else { throw LibraryMoveError.sourceChanged }
        let created = try await wenku.importForMove(from: web.fileURL(for: book), sourceBook: book)
        do { try await web.removeForMove(book) }
        catch {
            let failure = error
            do { try await Task { try await wenku.removeForMove(created) }.value }
            catch { throw LibraryMoveError.rollbackFailed }
            throw failure
        }
        state.transfer(from: "web:\(book.id)", to: "wenku:\(created.id.uuidString)")
    }

    static func moveToNetwork(_ book: LocalWenkuEPUB, web: WebNovelDownloadStore,
                              wenku: WenkuLocalLibraryStore, state: LibraryStateStore) async throws {
        try await wenku.loadIfNeeded()
        guard wenku.books.contains(book) else { throw LibraryMoveError.sourceChanged }
        let created = try await web.importForMove(from: wenku.fileURL(for: book), book: book)
        do { try await wenku.removeForMove(book) }
        catch {
            let failure = error
            do { try await Task { try await web.removeForMove(created) }.value }
            catch { throw LibraryMoveError.rollbackFailed }
            throw failure
        }
        state.transfer(from: "wenku:\(book.id.uuidString)", to: "web:\(created.id)")
    }
}

private let epubImportLog = Logger(subsystem: "cc.novelia.ios.port", category: "epub")

private enum LibraryMoveError: LocalizedError {
    case rollbackFailed, sourceChanged
    var errorDescription: String? {
        switch self {
        case .rollbackFailed: "原书已保留，但目标书库的副本清理失败。请检查两个书库后重试，阅读进度未转移。"
        case .sourceChanged: "书籍已被修改或移除，请刷新书库后重试。"
        }
    }
}
