import SwiftUI
import UIKit

// MARK: - 打开阅读

/// 沿用原有阅读器：TXT 使用 TXT 阅读器，EPUB 使用 EPUB 阅读器。
struct LibraryReaderDestination: View {
    let book: LibraryBook
    @StateObject private var rules = TXTChapterRuleStore.shared

    var body: some View {
        Group {
        if book.format == .txt {
            DownloadedWebNovelTXTReader(url: book.fileURL, title: book.title, rules: rules.configuration, statisticsID: book.key)
        } else if case .webNovel(let record) = book.origin, record.novel.isRemote {
            WebNovelEPUBReader(book: record)
        } else {
            EPUBReaderHost(initialURL: book.fileURL, statisticsID: book.key, statisticsTitle: book.title)
        }
        }
        .environment(\.speechBookRoute, .library(book.key))
    }
}

// MARK: - 书籍详细信息

/// 书库列表只保留书名、作者、格式与字数；来源、系列、文库分卷、阅读状态和文件信息集中在这里。
struct LibraryBookDetailView: View {
    let book: LibraryBook
    var embedded = false

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: LibraryStateStore
    @EnvironmentObject private var wordCounts: LibraryWordCountStore

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var hash: String? { state.hashByBook[book.key] ?? book.cloudFileHash }

    var body: some View {
        if embedded { detailContent }
        else { CompatNavigationStack { detailContent } }
    }

    private var detailContent: some View {
        let status = state.status(for: book)
        return Form {
                if embedded {
                    Section {
                        BrowseReadingLink(destination: .library(book)) {
                            Label("阅读本书", systemImage: "book.fill")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("library-detail-read")
                        .disabled(book.isCloudOnly)
                    }
                }
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        LibraryCoverView(book: book, width: 72, height: 100, fitMode: state.coverFitMode(for: book))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title)
                                .font(.headline)
                                .foregroundStyle(NoveliaStyle.ink)
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(.subheadline)
                                .foregroundStyle(NoveliaStyle.muted)
                            Text(book.format.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(NoveliaStyle.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                Section("书籍") {
                    CompatLabeledContent("来源", value: book.categoryTitle)
                    if case .wenku(let record) = book.origin {
                        CompatLabeledContent("文库作品", value: record.parentWenkuTitle ?? "未关联")
                        CompatLabeledContent("分卷", value: record.volumeID ?? "未关联")
                    }
                    CompatLabeledContent("系列", value: state.seriesName(for: book) ?? "未分组")
                    if book.coverURL != nil {
                        Picker("封面显示", selection: Binding(
                            get: { state.coverFitMode(for: book) },
                            set: { state.setCoverFitMode($0, for: book) }
                        )) {
                            ForEach(LibraryBookCoverFitMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    }
                    CompatLabeledContent("字数", value: wordCounts.total(hash: hash).map(BookWordCount.format) ?? "正在统计…")
                }
                Section("阅读") {
                    Picker("阅读分类", selection: Binding(
                        get: { state.bookStatus(for: book) },
                        set: { state.setBookStatus($0, for: book) }
                    )) {
                        ForEach(LibraryBookStatus.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    CompatLabeledContent("进度", value: status.detail)
                    CompatLabeledContent("最近阅读", value: status.lastReadAt.map { Self.dateFormatter.string(from: $0) } ?? "尚未阅读")
                }
                Section("文件") {
                    CompatLabeledContent("导入时间", value: Self.dateFormatter.string(from: book.importedAt))
                    CompatLabeledContent("本机文件", value: localFileText)
                    CompatLabeledContent("云端", value: cloudStateText)
                }
            }
            .compatScrollContentBackgroundHidden()
            .background(NoveliaStyle.paper.ignoresSafeArea())
            .navigationTitle(embedded ? "书籍详情" : "详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if !embedded { Button("完成") { dismiss() } }
                }
            }
            .task {
                if let hash { wordCounts.request(book, hash: hash) }
            }
    }

    private var localFileText: String {
        guard !book.isCloudOnly else { return "仅云端，未下载" }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: book.fileURL.path),
              let size = attributes[.size] as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var cloudStateText: String {
        if book.cloudFileMissing { return "云端文件已移除" }
        if book.isCloudOnly { return "仅云端，未下载" }
        return book.cloudFileHash == nil ? "仅本机" : "本机与云端"
    }
}
