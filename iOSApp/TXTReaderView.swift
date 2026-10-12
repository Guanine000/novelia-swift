import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct DownloadedWebNovelTXTReader: View {
    @ObservedObject private var settings = ReaderSettings.shared
    private var fontSize: Double { settings.fontSize }
    @Environment(\.colorScheme) private var systemColorScheme
    let url: URL
    let title: String
    let rules: TXTChapterRuleConfiguration
    @State private var chapters: [TXTChapter]?
    @State private var chapterIndex = 0
    @State private var bodyChunks: [String] = []
    @State private var bodyChunksChapterIndex: Int?
    @State private var isShowingContents = false
    @State private var errorMessage: String?

    private var appearance: ReaderAppearance {
        settings.appearance
    }

    var body: some View {
        Group {
            if let chapters, chapters.indices.contains(chapterIndex) {
                let chapter = chapters[chapterIndex]
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Color.clear.frame(height: 1).id("txt-reader-top")
                            if let volumeTitle = chapter.volumeTitle {
                                Text(volumeTitle)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                            }
                            Text(chapter.title)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                            if bodyChunksChapterIndex == chapterIndex {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(bodyChunks.indices, id: \.self) { index in
                                        Text(bodyChunks[index])
                                            .font(.system(size: fontSize, design: .serif))
                                            .lineSpacing(9)
                                            .foregroundStyle(appearance.primaryText(system: systemColorScheme))
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                ProgressView("正在排版章节…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 36)
                    }
                    .onChange(of: chapterIndex) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("txt-reader-top", anchor: .top)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        chapterControls(count: chapters.count)
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("无法读取 TXT", systemImage: "doc.text.magnifyingglass", description: Text(errorMessage))
            } else {
                ProgressView("正在打开 TXT…")
            }
        }
        .background(ReaderBackgroundView(dark: appearance.isDark(system: systemColorScheme), fallback: appearance.background(system: systemColorScheme)).ignoresSafeArea())
        .preferredColorScheme(appearance.preferredColorScheme)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if chapters != nil {
                    Button { isShowingContents = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("章节目录")
                }
                Button { settings.adjustFontSize(by: -1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .accessibilityLabel("缩小字号")
                Button { settings.adjustFontSize(by: 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityLabel("放大字号")
                Menu {
                    Picker("阅读主题", selection: $settings.appearanceRaw) {
                        ForEach(ReaderAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityLabel("阅读主题")
            }
        }
        .sheet(isPresented: $isShowingContents) {
            NavigationStack {
                List {
                    if let chapters {
                        ForEach(chapters.indices, id: \.self) { index in
                            Button {
                                chapterIndex = index
                                isShowingContents = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let volume = chapters[index].volumeTitle {
                                        Text(volume).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(chapters[index].title)
                                        .foregroundStyle(index == chapterIndex ? NoveliaStyle.brandGreen : .primary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("章节目录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isShowingContents = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: url) {
            do {
                chapters = try await Task.detached(priority: .userInitiated) {
                    let text = try TXTTextDecoder.decode(contentsOf: url)
                    return TXTChapterParser.parse(text, rules: rules)
                }.value
            } catch {
                let nsError = error as NSError
                TXTDiagnosticLog.logger.error("TXT reader load failed; domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
        .task(id: "\(url.path)|\(chapterIndex)|\(chapters?.count ?? 0)") {
            guard let chapters, chapters.indices.contains(chapterIndex) else { return }
            let body = chapters[chapterIndex].body
            let chunks = await Task.detached(priority: .userInitiated) {
                ReaderTextChunker.chunks(body)
            }.value
            guard !Task.isCancelled else { return }
            bodyChunks = chunks
            bodyChunksChapterIndex = chapterIndex
        }
    }

    private func chapterControls(count: Int) -> some View {
        HStack {
            Button {
                chapterIndex = max(0, chapterIndex - 1)
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(chapterIndex == 0)
            Spacer()
            Text("\(chapterIndex + 1) / \(count)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(appearance.secondaryText(system: systemColorScheme))
            Spacer()
            Button {
                chapterIndex = min(count - 1, chapterIndex + 1)
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(chapterIndex >= count - 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}
