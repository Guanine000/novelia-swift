import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

private enum LibraryImportError: LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        "只支持导入 .txt、.epub、.azw3 或 .mobi 文件。"
    }
}

private let kindleImportLog = Logger(subsystem: "cc.novelia.ios.port", category: "kindleimport")

/// 书库的 TXT / EPUB / AZW3 / MOBI 导入：复制文件、登记到文库书目并记录诊断日志。
/// AZW3／MOBI 先经用户确认，再由 `KindleEPUBConverter` 转为 EPUB 后按 EPUB 登记；原文件不保留。
@MainActor
final class LibraryImportModel: ObservableObject {
    /// 等待用户确认“转换为 EPUB”的一批文件。
    struct PendingKindleImport: Identifiable {
        let id = UUID()
        let urls: [URL]
        let kindleFilenames: [String]
    }

    @Published var isShowingFileImporter = false
    @Published var pendingKindleImport: PendingKindleImport?
    @Published private(set) var isImporting = false
    @Published private(set) var isConvertingKindle = false
    @Published private(set) var importCompletedCount = 0
    @Published private(set) var importTotalCount = 0
    @Published var importError: String?

    private var library: WenkuLocalLibraryStore!

    func attach(_ library: WenkuLocalLibraryStore) {
        self.library = library
    }

    /// 导入前的转换说明（与 docs/FEATURES.md 的“本地书籍导入”一致）。
    static func kindleConversionNotice(for filenames: [String]) -> String {
        let listed = filenames.prefix(5).joined(separator: "\n")
        let more = filenames.count > 5 ? "\n等 \(filenames.count) 个文件" : ""
        return "\(listed)\(more)\n\n以上 \(filenames.count) 个文件将转换为 EPUB 后导入。书库只保存转换后的 EPUB，导出时得到的也是 EPUB，原文件不会保存。部分 Kindle 专属效果（分格放大、纸书页码等）可能无法保留。"
    }

    static func isKindleFile(_ url: URL) -> Bool {
        KindleEPUBConverter.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 选择器回调：含 AZW3／MOBI 时先请用户确认转换，否则直接导入。
    func handlePickedFiles(_ pickedURLs: [URL]) async {
        guard !pickedURLs.isEmpty, !isImporting, pendingKindleImport == nil else { return }
        let kindle = pickedURLs.filter(Self.isKindleFile)
        guard kindle.isEmpty else {
            pendingKindleImport = PendingKindleImport(urls: pickedURLs, kindleFilenames: kindle.map(\.lastPathComponent))
            return
        }
        await importFiles(pickedURLs)
    }

    /// 用户对转换确认的回应；取消时只跳过 Kindle 文件，同批的 EPUB／TXT 照常导入。
    func resolvePendingKindleImport(convert: Bool) async {
        guard let pending = pendingKindleImport else { return }
        pendingKindleImport = nil
        await importFiles(convert ? pending.urls : pending.urls.filter { !Self.isKindleFile($0) })
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
        var converted = 0
        for (index, pickedURL) in pickedURLs.enumerated() {
            defer { importCompletedCount = index + 1 }
            guard seenPaths.insert(pickedURL.standardizedFileURL.path).inserted else { continue }
            do {
                try await importFile(pickedURL)
                if Self.isKindleFile(pickedURL) { converted += 1 }
            } catch let duplicate as LocalLibraryDuplicateError {
                duplicates.append("\(pickedURL.lastPathComponent)：已存在（《\(duplicate.existingTitle)》）")
            } catch {
                failures.append("\(pickedURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        let succeeded = seenPaths.count - failures.count - duplicates.count
        if !failures.isEmpty || !duplicates.isEmpty {
            var summary = "批量导入完成：成功 \(succeeded) 个"
            if converted > 0 { summary += "（其中 \(converted) 个已转换为 EPUB）" }
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
        let isKindle = Self.isKindleFile(pickedURL)
        guard extensionName == "txt" || extensionName == "epub" || isKindle else {
            throw LibraryImportError.unsupportedFile
        }
        let needsScope = pickedURL.startAccessingSecurityScopedResource()
        defer { if needsScope { pickedURL.stopAccessingSecurityScopedResource() } }
        let destination = library.downloadDestination(for: pickedURL.lastPathComponent)
        // 先在主线程占住文件名：复制期间同目录的文库下载不会选到同一个目标。
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        // 协调读取可能需要先从 iCloud 下载，大文件复制也很耗时，都放到主线程之外，进度浮窗保持更新。
        if isKindle {
            try await convertKindleFile(pickedURL, to: destination, start: start)
        } else {
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
            if extensionName == "epub" || isKindle { logEPUBImportFailure(error, stage: "registration", start: start) }
            if extensionName == "txt" {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT import registration failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
            }
            throw error
        }
        if extensionName == "txt" {
            let hash = (try? await TXTBookCache.shared.contentHash(of: destination)) ?? ""
            TXTDiagnosticLog.logger.info("TXT import completed; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(hash), privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        } else if isKindle {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            kindleImportLog.info("Kindle import completed; format=\(extensionName, privacy: .public), epubBytes=\(bytes, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
        } else {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            epubImportLog.info("EPUB import completed; bytes=\(bytes, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
        }
    }

    /// 先把选中的文件协调复制到临时目录（可能需要从 iCloud 下载），再在主线程之外转换为 EPUB 写到书库目标。
    /// 任一步失败都删除临时副本与目标占位文件；临时副本在转换后删除，书库不保留原文件。
    private func convertKindleFile(_ pickedURL: URL, to destination: URL, start: ContinuousClock.Instant) async throws {
        let format = pickedURL.pathExtension.lowercased()
        kindleImportLog.info("Kindle import started; format=\(format, privacy: .public)")
        isConvertingKindle = true
        defer { isConvertingKindle = false }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("kindle-import-\(UUID().uuidString).\(format)")
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try Self.coordinatedCopy(from: pickedURL, to: staging)
            } catch {
                return .failure(KindleConversionStageError.copy(error))
            }
            do {
                try await KindleEPUBConverter.convert(source: staging, destination: destination)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        guard case .failure(let error) = result else { return }
        try? FileManager.default.removeItem(at: destination)
        switch error {
        case KindleConversionStageError.copy(let underlying):
            let nsError = underlying as NSError
            kindleImportLog.error("Kindle import failed; stage=copy, domain=\(ShareableLogPolicy.domainLabel(nsError.domain), privacy: .public), code=\(nsError.code, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
            throw underlying
        case let kindleError as KindleImportError:
            kindleImportLog.error("Kindle import failed; stage=convert, reason=\(String(describing: kindleError), privacy: .public), format=\(format, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
            throw kindleError
        default:
            let nsError = error as NSError
            kindleImportLog.error("Kindle import failed; stage=write, domain=\(ShareableLogPolicy.domainLabel(nsError.domain), privacy: .public), code=\(nsError.code, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
            throw KindleImportError.conversionFailed
        }
    }

    private enum KindleConversionStageError: Error {
        case copy(Error)
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
                    Label(model.isConvertingKindle ? "正在转换为 EPUB" : "正在导入书籍", systemImage: "books.vertical")
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
