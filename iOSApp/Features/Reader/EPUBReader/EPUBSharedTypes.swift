import CoreText
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 阅读样式与导入字体。Readium 与原生分页共用，且不依赖 YueduCoreText。
// iOS 15 目标不编译原生分页源文件，因此这两类放在独立文件里，两个 App 目标都编译。

/// 阅读器自己的排版偏好；字体名称来自设备当前可用的 UIFont 字体族。
struct EPUBReaderStyle: Codable, Equatable {
    var doublePage: Bool? = false
    var fontSize: CGFloat = 21
    var fontFamily: String? = nil
    var lineSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
    /// nil 保留书籍原样；0、1、2 等值覆盖段落首行缩进（em）。
    var firstLineIndentEm: CGFloat? = nil
    var topMargin: CGFloat = 64
    var bottomMargin: CGFloat = 72
    var leftMargin: CGFloat = 20
    var rightMargin: CGFloat = 20

    var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: topMargin, left: leftMargin, bottom: bottomMargin, right: rightMargin)
    }

    var readerCSS: String? {
        var rules: [String] = []
        if let fontFamily {
            let escaped = fontFamily.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            rules.append("body, p { font-family: '\(escaped)' !important; }")
        }
        if let firstLineIndentEm {
            rules.append("p { text-indent: \(firstLineIndentEm)em !important; }")
        }
        return rules.isEmpty ? nil : rules.joined(separator: "\n")
    }
}

@MainActor
enum EPUBLocalFonts {
    struct ImportedFont: Identifiable {
        let url: URL
        let family: String
        var id: URL { url }
        var format: String { url.pathExtension.uppercased() }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EPUBReaderFonts", isDirectory: true)
    }

    static func registerSavedFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func importFont(from sourceURL: URL) throws -> String {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        guard ["ttf", "otf", "ttc"].contains(sourceURL.pathExtension.lowercased()) else {
            throw FontImportError.unsupportedFormat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.lowercased())
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let registered = CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(destination as CFURL) as? [CTFontDescriptor],
              let family = descriptors.compactMap({ CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }).first else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        guard registered || UIFont.familyNames.contains(family) else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        let hash = try FileContentHash.sha256(destination)
        recordSync(SyncedImportedFont(hash: hash, format: destination.pathExtension, deleted: false, updatedAt: Date()))
        return family
    }

    static func importedFonts() -> [ImportedFont] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  let family = descriptors.compactMap({
                      CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
                  }).first else { return nil }
            return ImportedFont(url: file, family: family)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    static func deleteFont(_ font: ImportedFont) throws {
        guard font.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw FontImportError.invalidLocation
        }
        let hash = try FileContentHash.sha256(font.url)
        CTFontManagerUnregisterFontsForURL(font.url as CFURL, .process, nil)
        try FileManager.default.removeItem(at: font.url)
        recordSync(SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: true, updatedAt: Date()))
    }

    static func syncSnapshot() throws -> [String: SyncedImportedFont] {
        var records = syncRecords()
        for font in importedFonts() {
            let hash = try FileContentHash.sha256(font.url)
            if records[hash] == nil { records[hash] = SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: false, updatedAt: .distantPast) }
        }
        return records
    }
    static func syncFiles() throws -> [String: URL] {
        var files: [String: URL] = [:]
        for font in importedFonts() { files[try FileContentHash.sha256(font.url)] = font.url }
        return files
    }
    private static func syncRecords() -> [String: SyncedImportedFont] {
        UserDefaults.standard.data(forKey: SettingsKey.importedFontSync).flatMap { try? JSONDecoder().decode([String: SyncedImportedFont].self, from: $0) } ?? [:]
    }
    private static func recordSync(_ record: SyncedImportedFont) {
        var records = syncRecords(); records[record.hash] = record
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: SettingsKey.importedFontSync) }
    }
    static func applySync(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {
        for (hash, record) in records {
            if let local = syncRecords()[hash], local.updatedAt > record.updatedAt { continue }
            let matches = try importedFonts().filter { try FileContentHash.sha256($0.url) == hash }
            if record.deleted {
                for font in matches { try deleteFont(font) }
            } else if matches.isEmpty {
                guard ["ttf", "otf", "ttc"].contains(record.format), let file = files[hash] else { throw CocoaError(.fileReadCorruptFile) }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(record.format)
                try FileManager.default.copyItem(at: file, to: temporary)
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try importFont(from: temporary)
            }
            recordSync(record)
        }
        NotificationCenter.default.post(name: Notification.Name("NoveliaImportedFontsChanged"), object: nil)
    }

    private enum FontImportError: LocalizedError {
        case unsupportedFormat, registrationFailed, invalidLocation
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "请选择 TTF、OTF 或 TTC 字体文件。"
            case .registrationFailed: "无法注册该字体文件，请确认文件完整且格式受 iOS 支持。"
            case .invalidLocation: "只能删除本应用导入的字体。"
            }
        }
    }
}

/// 注释浮层的正文。原生分页与 Readium 共用，不依赖 YueduCoreText。
struct EPUBNote: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// 分页阅读器显示的生成章节（TXT / 在线小说），代替 EPUB 文件。
struct PagedTextBook {
    let source: any EPUBChapterSource
    let startUnit: Int
    let startOffset: Int?
    /// （单元序号，单元文本中的 UTF-16 偏移量），每次翻页后报告。
    let onPosition: (Int, Int?) -> Void
    /// TXT 的 Readium Locator 独立保存，身份包含内容哈希及分章规则。
    var readiumIdentity: String? = nil
    var positionUpdatedAt: Date? = nil
    /// 书签与书内搜索使用的身份（本地 TXT 为 `txt:<文件哈希>`）；在线小说书签身份为 nil，搜索通过本机缓存回调提供。
    var bookmarkKey: String? = nil
    var preferenceKey: String? = nil
    var searchChapterText: ((Int) async throws -> String)? = nil
    /// 目录字数（本地 TXT）；在线小说为 nil，不显示字数。
    var tocWordCounts: (@Sendable () async -> ReaderTOCWordCounts)? = nil
    var adjustTXTChapters: (() -> Void)? = nil
    /// 仅本地 TXT 提供；在线文本不提供，避免为预测请求正文。
    var localRecapBook: TXTParsedBook? = nil
    var localTimeMetrics: (@Sendable (ReadingTextProjection) async throws -> ReadingTimeMetrics)? = nil
}


/// UIFont 列出的字体族包含系统字体以及已安装且对本 App 可见的设备字体。
struct EPUBFontPicker: View {
    @Binding var selection: String?
    var onDeleteImportedFamily: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var families: [String] {
        UIFont.familyNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            NavigationLink {
                EPUBImportedFontsView(selection: $selection,
                                           onDeleteImportedFamily: onDeleteImportedFamily)
            } label: {
                Label("管理导入的字体", systemImage: "square.and.arrow.down")
            }
            Button {
                selection = nil
                dismiss()
            } label: {
                HStack {
                    Text("书籍默认")
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark") }
                }
            }
            ForEach(families, id: \.self) { family in
                Button {
                    selection = family
                    dismiss()
                } label: {
                    HStack {
                        Text(family)
                            .font(.custom(UIFont.fontNames(forFamilyName: family).first ?? family, size: 17))
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection == family { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .navigationTitle("本机字体")
        .searchable(text: $query, prompt: "搜索字体")
    }
}

private struct EPUBImportedFontsView: View {
    @Binding var selection: String?
    var onDeleteImportedFamily: (String) -> Void
    @State private var fonts: [EPUBLocalFonts.ImportedFont] = []
    @State private var isImportingFont = false
    @State private var importError: String?
    @State private var importedFamily: String?
    @State private var fontToDelete: EPUBLocalFonts.ImportedFont?

    var body: some View {
        List {
            Button {
                isImportingFont = true
            } label: {
                Label("从“文件”导入字体", systemImage: "plus")
            }
            if let importedFamily {
                Text("已导入并选中：\(importedFamily)。返回阅读设置后点击“应用”生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if fonts.isEmpty {
                CompatUnavailable("尚未导入字体", systemImage: "textformat",
                                       description: Text("支持从“文件”导入 TTF、OTF、TTC 字体。"))
            } else {
                ForEach(fonts) { font in
                    HStack {
                        Button {
                            selection = font.family
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(font.family)
                                    Text(font.format).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == font.family { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            fontToDelete = font
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除 \(font.family)")
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { fontToDelete = font }
                    }
                }
            }
        }
        .navigationTitle("导入的字体")
        .onAppear { reload() }
        .sheet(isPresented: $isImportingFont) {
            EPUBFilePicker(contentTypes: [.item]) { urls in
                isImportingFont = false
                guard let url = urls.first else { return }
                do {
                    let family = try EPUBLocalFonts.importFont(from: url)
                    selection = family
                    importedFamily = family
                    reload()
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("字体导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("删除导入的字体？", isPresented: Binding(
            get: { fontToDelete != nil },
            set: { if !$0 { fontToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除字体文件", role: .destructive) {
                if let fontToDelete { delete(fontToDelete) }
                fontToDelete = nil
            }
            Button("取消", role: .cancel) { fontToDelete = nil }
        } message: {
            Text("删除后如需再次使用，请重新导入字体文件。")
        }
    }

    private func reload() {
        fonts = EPUBLocalFonts.importedFonts()
    }

    private func delete(_ font: EPUBLocalFonts.ImportedFont) {
        do {
            try EPUBLocalFonts.deleteFont(font)
            if selection == font.family { selection = nil }
            onDeleteImportedFamily(font.family)
            if importedFamily == font.family { importedFamily = nil }
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - 文件选择（UIKit 文档选择器：iCloud 按需下载可靠，任意文件可选）

struct EPUBFilePicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.data]
    var allowsMultipleSelection = false
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // copy 导入模式：系统把所选文件复制进应用沙箱后回调，
        // 不受 open 模式的 UTI 启用规则与 iCloud 占位文件影响，条目总能点选。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - 打开入口（注入样例书或指定 EPUB；以全屏页方式呈现）

struct EPUBReaderHost: View {
    @EnvironmentObject private var settings: ReaderSettings
    @State private var preferenceID: String?
    let initialURL: URL?
    var statisticsID: String? = nil
    var statisticsTitle: String? = nil
    var webContext: WebNovelEPUBContext? = nil
    var onReachedEnd: (() -> Void)? = nil
    var accessory: AnyView? = nil
    @State private var resolvedURL: URL?
    /// 实验：EPUB 改由 Readium（WKWebView）排版。iOS 15 目标没有原生分页，固定走 Readium。
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var usesReadium = false
    #endif

    private func descriptor(for url: URL) -> ReadingBook {
        ReadingBook(id: statisticsID ?? "epub:\(url.lastPathComponent)",
                    title: statisticsTitle ?? url.deletingPathExtension().lastPathComponent, kind: .epub)
    }

    /// 调试：Debug 构建中 `-prototypeBookPath <路径>` 直接打开指定 EPUB（自动化/真机排查用）。
    private var debugBookURL: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-prototypeBookPath"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
        #else
        return nil
        #endif
    }

    var body: some View {
        Group {
            if let resolvedURL {
                #if NOVELIA_READIUM_ONLY
                ReadiumEPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                #else
                if usesReadium {
                    ReadiumEPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                } else {
                    EPUBReaderView(bookURL: resolvedURL, accessory: accessory, statisticsBook: descriptor(for: resolvedURL), webContext: webContext, onReachedEnd: onReachedEnd)
                }
                #endif
            } else {
                ProgressView("准备样例书…")
            }
        }
        .onDisappear { if let preferenceID { settings.deactivateBook(preferenceID) } }
        .task {
            if resolvedURL == nil {
                if let debugBookURL {
                    resolvedURL = debugBookURL
                } else if let initialURL {
                    let hash = try? await Task.detached { try FileContentHash.sha256(initialURL) }.value
                    let id = webContext?.bookKey ?? hash.map { "epub:\($0)" } ?? "file:\(initialURL.lastPathComponent)"
                    settings.activateBook(id); preferenceID = id
                    resolvedURL = initialURL
                } else {
                    #if DEBUG
                    resolvedURL = try? await EPUBSampleBook.sampleURL()
                    #endif
                }
            }
        }
    }
}


// MARK: - 可折叠目录（YueduCoreText 与 Readium 阅读器共用）

/// 目录顶部的全书字数（口径见 `BookWordCount`）。
struct ReaderTOCWordCountHeader: View {
    let total: Int

    var body: some View {
        Text("全书 \(BookWordCount.format(total))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("全书字数 \(BookWordCount.format(total))")
    }
}

/// 目录面板的导航栏按钮。iOS 16 及以上按条件插入项目；
/// iOS 15 的 `ToolbarContentBuilder` 不能生成 `Optional`，改成确定的按钮组合。
struct ReaderTOCNavigationToolbar: ViewModifier {
    let showsImageTabs: Bool
    let levels: [Int]
    @Binding var tocTab: ReaderTOCTab
    @Binding var expanded: Set<Int>
    let onClose: () -> Void

    private var showsExpand: Bool {
        (tocTab == .contents || !showsImageTabs) && levels.contains { $0 > 0 }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.toolbar {
                ToolbarItem(placement: .compatTopBarLeading) { Button("关闭", action: onClose) }
                if showsImageTabs {
                    ToolbarItem(placement: .principal) { ReaderTOCTabPicker(selection: $tocTab) }
                }
                if showsExpand {
                    ToolbarItem(placement: .compatTopBarTrailing) {
                        ReaderTOCExpandAllButton(levels: levels, expanded: $expanded)
                    }
                }
            }
        } else if showsImageTabs && showsExpand {
            content.toolbar { closeButton; imageTabs; expandButton }
        } else if showsImageTabs {
            content.toolbar { closeButton; imageTabs }
        } else if showsExpand {
            content.toolbar { closeButton; expandButton }
        } else {
            content.toolbar { closeButton }
        }
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarLeading) { Button("关闭", action: onClose) }
    }

    private var imageTabs: some ToolbarContent {
        ToolbarItem(placement: .principal) { ReaderTOCTabPicker(selection: $tocTab) }
    }

    private var expandButton: some ToolbarContent {
        ToolbarItem(placement: .compatTopBarTrailing) {
            ReaderTOCExpandAllButton(levels: levels, expanded: $expanded)
        }
    }
}

/// 目录右上角的「全部展开／全部折叠」。
struct ReaderTOCExpandAllButton: View {
    let levels: [Int]
    @Binding var expanded: Set<Int>

    var body: some View {
        let flags = TOCOutline.hasChildren(levels: levels)
        let groups = Set(levels.indices.filter { flags[$0] })
        let allExpanded = !groups.isEmpty && groups.isSubset(of: expanded)
        Button(allExpanded ? "全部折叠" : "全部展开") {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = allExpanded ? [] : groups }
        }
    }
}
