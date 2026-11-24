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

    /// 轻量体检发现结构/目录/封面异常的一批 EPUB，等待用户确认是否修复并标准化后再导入。
    struct PendingEPUBRepair: Identifiable {
        struct Item: Equatable {
            let url: URL
            let filename: String
            let summary: String
        }
        let id = UUID()
        let urls: [URL]
        let problematicItems: [Item]
        var problematicURLSet: Set<URL> { Set(problematicItems.map(\.url)) }
    }

    enum EPUBRepairDecision {
        case repairAndImport
        case importOriginal
        case skipProblematic
    }

    @Published var isShowingFileImporter = false
    @Published var pendingKindleImport: PendingKindleImport?
    @Published var pendingEPUBRepair: PendingEPUBRepair?
    @Published private(set) var isInspectingEPUB = false
    @Published private(set) var isImporting = false
    @Published private(set) var isConvertingKindle = false
    @Published private(set) var isRepairingEPUB = false
    @Published private(set) var importCompletedCount = 0
    @Published private(set) var importTotalCount = 0
    @Published var importError: String?

    private var library: WenkuLocalLibraryStore!
    @Published private(set) var isStagingDrop = false
    /// 从接收拖放到转换/体检确认、实际导入结束，共用同一入口互斥状态。
    var isBusy: Bool {
        isStagingDrop || isInspectingEPUB || isImporting
            || pendingKindleImport != nil || pendingEPUBRepair != nil
    }
    private var dropStagingDirectory: URL?

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

    /// 导入前 EPUB 轻量结构体检的汇总提示。
    static func epubRepairNotice(for items: [PendingEPUBRepair.Item]) -> String {
        let listed = items.prefix(5).map { "\($0.filename)：\($0.summary)" }.joined(separator: "\n")
        let more = items.count > 5 ? "\n等 \(items.count) 个 EPUB 文件" : ""
        return "\(listed)\(more)\n\n是否使用 EPUB 工具箱执行目录结构标准化、XHTML 良构修复、OPF/目录/封面修复与冗余资源清理后再导入？（不会修改原始文件）"
    }

    private static var shouldInspectEPUBOnImport: Bool {
        if UserDefaults.standard.object(forKey: SettingsKey.libraryAutoInspectEPUBOnImport) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: SettingsKey.libraryAutoInspectEPUBOnImport)
    }

    /// 选择器回调：含 AZW3／MOBI 时先请用户确认转换，再按设置对 EPUB 执行轻量结构体检。
    func handlePickedFiles(_ pickedURLs: [URL]) async {
        guard !pickedURLs.isEmpty, !isBusy else { return }
        let kindle = pickedURLs.filter(Self.isKindleFile)
        guard kindle.isEmpty else {
            pendingKindleImport = PendingKindleImport(urls: pickedURLs, kindleFilenames: kindle.map(\.lastPathComponent))
            return
        }
        await inspectEPUBsOrImport(pickedURLs)
    }

    /// 接收 iPad 分屏或文件拖放：将拖入项复制到临时目录后复用统一导入管线，导入结束后清理临时目录。
    func handleDroppedProviders(_ providers: [NSItemProvider], contentTypes: [UTType]) -> Bool {
        guard !providers.isEmpty, !isBusy else { return false }
        let matched = providers.filter { provider in
            contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
                || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !matched.isEmpty else { return false }
        isStagingDrop = true
        Task {
            defer { isStagingDrop = false }
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("library-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            var stagedURLs: [URL] = []
            for (index, provider) in matched.enumerated() {
                if let url = await Self.stageDroppedFile(from: provider, matching: contentTypes, into: stagingRoot, index: index) {
                    stagedURLs.append(url)
                }
            }
            guard !stagedURLs.isEmpty else {
                try? FileManager.default.removeItem(at: stagingRoot)
                importError = LibraryImportError.unsupportedFile.localizedDescription
                return
            }
            dropStagingDirectory = stagingRoot
            // 同一主执行器上交接状态，中间没有挂起点，外部入口无法插入。
            isStagingDrop = false
            await handlePickedFiles(stagedURLs)
            if pendingKindleImport == nil && pendingEPUBRepair == nil {
                cleanupDropStagingDirectory()
            }
        }
        return true
    }

    /// 用户对转换确认的回应；取消时只跳过 Kindle 文件，同批的 EPUB／TXT 照常进入后续体检与导入。
    func resolvePendingKindleImport(convert: Bool) async {
        guard let pending = pendingKindleImport else { return }
        pendingKindleImport = nil
        let nextURLs = convert ? pending.urls : pending.urls.filter { !Self.isKindleFile($0) }
        await inspectEPUBsOrImport(nextURLs)
        if pendingEPUBRepair == nil {
            cleanupDropStagingDirectory()
        }
    }

    /// 对本批中的 `.epub` 执行轻量结构体检（不解压正文与图片）；若发现异常则弹出一次汇总确认。
    private func inspectEPUBsOrImport(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let epubURLs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        guard Self.shouldInspectEPUBOnImport, !epubURLs.isEmpty else {
            await importFiles(urls)
            return
        }

        isInspectingEPUB = true
        let problematic: [PendingEPUBRepair.Item] = await Task.detached(priority: .userInitiated) {
            var found: [PendingEPUBRepair.Item] = []
            for url in epubURLs {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                var coordError: NSError?
                var readableTarget: URL?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readableURL in
                    readableTarget = readableURL
                }
                let targetURL = readableTarget ?? url
                if let report = try? await EPUBToolboxInspector.inspect(url: targetURL, mode: .lightweight),
                   report.hasActionableIssues {
                    found.append(PendingEPUBRepair.Item(
                        url: url,
                        filename: url.lastPathComponent,
                        summary: report.shortSummary
                    ))
                }
            }
            return found
        }.value
        isInspectingEPUB = false

        if !problematic.isEmpty {
            pendingEPUBRepair = PendingEPUBRepair(urls: urls, problematicItems: problematic)
            return
        }
        await importFiles(urls)
    }

    /// 用户对 EPUB 体检弹窗的回应。
    func resolvePendingEPUBRepair(decision: EPUBRepairDecision) async {
        guard let pending = pendingEPUBRepair else { return }
        pendingEPUBRepair = nil
        defer { cleanupDropStagingDirectory() }
        switch decision {
        case .repairAndImport:
            await importFiles(pending.urls, epubRepairTargets: pending.problematicURLSet)
        case .importOriginal:
            await importFiles(pending.urls)
        case .skipProblematic:
            let targets = pending.problematicURLSet
            let remaining = pending.urls.filter { !targets.contains($0) }
            await importFiles(remaining)
        }
    }

    private func cleanupDropStagingDirectory() {
        guard let directory = dropStagingDirectory else { return }
        dropStagingDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated private static func stageDroppedFile(from provider: NSItemProvider, matching contentTypes: [UTType],
                                                     into stagingRoot: URL, index: Int) async -> URL? {
        let itemFolder = stagingRoot.appendingPathComponent("\(index)", isDirectory: true)
        try? FileManager.default.createDirectory(at: itemFolder, withIntermediateDirectories: true)
        for type in contentTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let staged = await stageFileRepresentation(from: provider, typeIdentifier: type.identifier, into: itemFolder) {
                return staged
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let staged = await stageFileRepresentation(from: provider, typeIdentifier: UTType.fileURL.identifier, into: itemFolder) {
            return staged
        }
        return nil
    }

    nonisolated private static func stageFileRepresentation(from provider: NSItemProvider, typeIdentifier: String,
                                                            into itemFolder: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let destination = itemFolder.appendingPathComponent(url.lastPathComponent)
                do {
                    try Self.coordinatedCopy(from: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 从“文件”批量导入：逐项复制并登记到本地书库。
    func importFiles(_ pickedURLs: [URL], epubRepairTargets: Set<URL> = []) async {
        // 一次只执行一个导入：复制期间再次收到选择器回调会重复登记相同文件。
        guard !pickedURLs.isEmpty, !isBusy else { return }
        isImporting = true
        importCompletedCount = 0
        importTotalCount = pickedURLs.count
        defer { isImporting = false }

        var failures: [String] = []
        var duplicates: [String] = []
        // 同一批次重复选择的文件只导入一次。
        var seenPaths = Set<String>()
        var converted = 0
        var repaired = 0
        for (index, pickedURL) in pickedURLs.enumerated() {
            defer { importCompletedCount = index + 1 }
            guard seenPaths.insert(pickedURL.standardizedFileURL.path).inserted else { continue }
            let shouldRepair = epubRepairTargets.contains(pickedURL)
            do {
                try await importFile(pickedURL, repairEPUB: shouldRepair)
                if Self.isKindleFile(pickedURL) { converted += 1 }
                if shouldRepair { repaired += 1 }
            } catch let duplicate as LocalLibraryDuplicateError {
                duplicates.append("\(pickedURL.lastPathComponent)：已存在（《\(duplicate.existingTitle)》）")
            } catch {
                failures.append("\(pickedURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        let succeeded = seenPaths.count - failures.count - duplicates.count
        if !failures.isEmpty || !duplicates.isEmpty {
            var summary = "批量导入完成：成功 \(succeeded) 个"
            var notes: [String] = []
            if converted > 0 { notes.append("\(converted) 个已转换为 EPUB") }
            if repaired > 0 { notes.append("\(repaired) 个已标准化修复") }
            if !notes.isEmpty { summary += "（其中 " + notes.joined(separator: "，") + "）" }
            if !duplicates.isEmpty { summary += "，已存在 \(duplicates.count) 个" }
            if !failures.isEmpty { summary += "，失败 \(failures.count) 个" }
            importError = summary + "。\n" + (duplicates + failures).joined(separator: "\n")
        }
    }

    private func importFile(_ pickedURL: URL, repairEPUB: Bool = false) async throws {
        try await library.loadIfNeeded()
        let extensionName = pickedURL.pathExtension.lowercased()
        let start = MonotonicInstant.now
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
        } else if repairEPUB && extensionName == "epub" {
            try await repairAndStandardizeEPUB(pickedURL, to: destination, start: start)
        } else {
            let copyResult = await Task.detached(priority: .userInitiated) {
                Result { try Self.coordinatedCopy(from: pickedURL, to: destination) }
            }.value
            if case .failure(let error) = copyResult {
                try? FileManager.default.removeItem(at: destination)
                if extensionName == "epub" { logEPUBImportFailure(error, stage: "copy", start: start) }
                if extensionName == "txt" {
                    let nsError = error as NSError
                    ShareableLogger(category: "txt").error(
                        AppDiagnosticMessage.txtImportFailed(stage: "copy", domain: nsError.domain, code: nsError.code, elapsedMs: Self.milliseconds(since: start))
                    )
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
                ShareableLogger(category: "txt").error(
                    AppDiagnosticMessage.txtImportFailed(stage: "registration", domain: nsError.domain, code: nsError.code, elapsedMs: Self.milliseconds(since: start))
                )
            }
            throw error
        }
        if extensionName == "txt" {
            let hash = (try? await TXTBookCache.shared.contentHash(of: destination)) ?? ""
            TXTDiagnosticLog.logger.info("TXT import completed; trace=\(trace, privacy: .public), book=\(DiagnosticContext.bookTag(hash), privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public), mono=\(DiagnosticContext.monotonicMilliseconds(), privacy: .public)")
        } else if isKindle {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            ShareableLogger(category: "kindleimport").notice(
                AppDiagnosticMessage.kindleImportCompleted(format: extensionName, epubBytes: bytes, elapsedMs: Self.milliseconds(since: start))
            )
        } else {
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            epubImportLog.info("EPUB import completed; bytes=\(bytes, privacy: .public), elapsedMs=\(Self.milliseconds(since: start), privacy: .public)")
        }
    }

    /// 先协调复制原 EPUB 到临时文件，再在后台运行 EPUB 工具箱标准化修复并写入目标路径。
    private func repairAndStandardizeEPUB(_ pickedURL: URL, to destination: URL, start: MonotonicInstant) async throws {
        isRepairingEPUB = true
        defer { isRepairingEPUB = false }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-repair-\(UUID().uuidString).epub")
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try Self.coordinatedCopy(from: pickedURL, to: staging)
                _ = try await EPUBToolboxProcessor.process(source: staging, destination: destination, options: .all)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = result {
            try? FileManager.default.removeItem(at: destination)
            logEPUBImportFailure(error, stage: "repair", start: start)
            throw error
        }
    }

    /// 先把选中的文件协调复制到临时目录（可能需要从 iCloud 下载），再在主线程之外转换为 EPUB 写到书库目标。
    /// 任一步失败都删除临时副本与目标占位文件；临时副本在转换后删除，书库不保留原文件。
    private func convertKindleFile(_ pickedURL: URL, to destination: URL, start: MonotonicInstant) async throws {
        let format = pickedURL.pathExtension.lowercased()
        kindleImportLog.info("\(AppDiagnosticMessage.kindleImportStarted(format: format), privacy: .public)")
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
            ShareableLogger(category: "kindleimport").error(
                AppDiagnosticMessage.kindleImportFailed(stage: "copy", format: format, reason: "io", domain: nsError.domain, code: nsError.code, elapsedMs: Self.milliseconds(since: start))
            )
            throw underlying
        case let kindleError as KindleImportError:
            let reason: String = switch kindleError {
            case .drmProtected: "drm"
            case .unsupportedKindleFormat, .printReplica: "unsupported"
            case .invalidFile: "corrupt"
            case .conversionFailed: "other"
            }
            ShareableLogger(category: "kindleimport").error(
                AppDiagnosticMessage.kindleImportFailed(stage: "convert", format: format, reason: reason, domain: "app", code: 0, elapsedMs: Self.milliseconds(since: start))
            )
            throw kindleError
        default:
            let nsError = error as NSError
            ShareableLogger(category: "kindleimport").error(
                AppDiagnosticMessage.kindleImportFailed(stage: "write", format: format, reason: "io", domain: nsError.domain, code: nsError.code, elapsedMs: Self.milliseconds(since: start))
            )
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

    private func logEPUBImportFailure(_ error: Error, stage: String, start: MonotonicInstant) {
        let nsError = error as NSError
        let domain = ShareableLogPolicy.domainLabel(nsError.domain)
        ShareableLogger(category: "epub").error("EPUB import failed; stage=\(stage), domain=\(domain), code=\(nsError.code), elapsedMs=\(Self.milliseconds(since: start))")
    }

    private static func milliseconds(since start: MonotonicInstant) -> Int {
        DiagnosticContext.milliseconds(since: start)
    }
}

/// 导入进度浮窗。
struct LibraryImportProgressOverlay: View {
    @ObservedObject var model: LibraryImportModel

    var body: some View {
        if model.isImporting || model.isInspectingEPUB {
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    let title: String = {
                        if model.isInspectingEPUB { return "正在检查 EPUB 结构" }
                        if model.isConvertingKindle { return "正在转换为 EPUB" }
                        if model.isRepairingEPUB { return "正在修复并标准化 EPUB" }
                        return "正在导入书籍"
                    }()
                    Label(title, systemImage: "books.vertical")
                        .font(.system(size: 16, weight: .semibold))
                    if model.isInspectingEPUB {
                        ProgressView()
                            .tint(NoveliaStyle.brandGreen)
                        Text("仅读取目录与清单元数据，请稍候…")
                            .font(NoveliaStyle.fontBody)
                            .foregroundStyle(NoveliaStyle.muted)
                    } else {
                        ProgressView(value: Double(model.importCompletedCount), total: Double(max(model.importTotalCount, 1)))
                            .tint(NoveliaStyle.brandGreen)
                        Text("已处理 \(model.importCompletedCount) / \(model.importTotalCount) 个文件")
                            .font(NoveliaStyle.fontBody)
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                }
                .padding(20)
                .frame(width: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge))
                .overlay(RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge).stroke(.white.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
            }
            .transition(.opacity)
        }
    }
}

/// 在“网络小说/文库”两个下载库之间移动书籍；系列归属与最近打开时间随新标识转移。
/// 网站更新缺失历史配置时共用的选择页；不请求网络，只有明确提交才开始更新。
struct WebNovelEPUBUpdateOptionsSheet: View {
    let book: DownloadedWebNovel
    let onConfirm: (WebNovelEPUBUpdateConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: WebNovelDownloadMode?
    @State private var source: NovelTranslationSource?
    init(book: DownloadedWebNovel, onConfirm: @escaping (WebNovelEPUBUpdateConfiguration) -> Void) {
        self.book = book; self.onConfirm = onConfirm
        _mode = State(initialValue: book.downloadMode)
        _source = State(initialValue: book.translationSource)
    }
    private var configuration: WebNovelEPUBUpdateConfiguration? {
        guard let mode else { return nil }
        let value = WebNovelEPUBUpdateConfiguration(mode: mode, translationSource: source)
        return value.isValid ? value : nil
    }
    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    Text(book.novel.title)
                    Text("这本书没有完整的历史下载设置，请确认本次更新的语言模式和译源。成功后会保存选择，后续更新沿用。").font(.footnote)
                }
                Section("语言模式") {
                    ForEach(WebNovelDownloadMode.allCases) { value in
                        Button { mode = value } label: {
                            HStack { Text(value.title); Spacer(); if mode == value { Image(systemName: "checkmark") } }
                        }.accessibilityLabel(value.title)
                    }
                }
                if let mode, mode != .original {
                    Section("翻译源") {
                        ForEach(NovelTranslationSource.allCases) { value in
                            Button { source = value } label: {
                                HStack { Text(value.title); Spacer(); if source == value { Image(systemName: "checkmark") } }
                            }.accessibilityLabel(value.title)
                        }
                    }
                }
                Button("确认并更新 EPUB") {
                    guard let configuration else { return }
                    dismiss(); onConfirm(configuration)
                }.disabled(configuration == nil)
            }
            .navigationTitle("选择更新设置")
            .navigationBarTitleDisplayMode(.inline)
            .compatToolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

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
