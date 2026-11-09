// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// 从各 TXT 阅读面的菜单进入；统一显示原文，避免文字替换后选区不能逆向定位。
struct TXTChapterAdjustmentView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let rules: TXTChapterRuleConfiguration
    let onSaved: () -> Void
    @State private var session: TXTAdjustmentSession?
    @State private var chapter = 0
    @State private var selection = NSRange(location: NSNotFound, length: 0)
    @State private var undo: [TXTAdjustmentDocument] = []
    @State private var isSaving = false
    @State private var error: String?
    @State private var showsContents = false
    @State private var confirmsDelete = false
    @State private var didSave = false
    @State private var textPage = 0

    /// 即使自动识别退回“全文”，UIKit 也只装载一段原文；边界按完整字符计算。
    private func visibleRange(_ document: TXTAdjustmentDocument) -> NSRange {
        let region = document.range(of: chapter)
        let source = document.text as NSString
        let page = min(max(0, textPage), max(0, region.length - 1) / 12_000)
        let start = region.location + page * 12_000
        let remaining = min(12_000, NSMaxRange(region) - start)
        let safe = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: remaining))
        return NSIntersectionRange(safe, region)
    }

    var body: some View {
        CompatNavigationStack {
            Group {
                if let session {
                    VStack(spacing: 0) {
                        Text("长按选择原文，再点“设为章节标题”自动生成新章。")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                        let region = visibleRange(session.document)
                        TXTAdjustmentSelectionView(text: (session.document.text as NSString).substring(with: region),
                                                   selection: $selection)
                        if session.document.range(of: chapter).length > 12_000 {
                            HStack {
                                Button("上一段原文") { textPage -= 1; selection.length = 0 }.disabled(textPage == 0)
                                Spacer()
                                Button("下一段原文") { textPage += 1; selection.length = 0 }
                                    .disabled(NSMaxRange(region) >= NSMaxRange(session.document.range(of: chapter)))
                            }.font(.footnote).padding(.horizontal)
                        }
                        HStack {
                            Button("上一章") { move(-1) }.disabled(chapter == 0)
                            Spacer()
                            Button("\(chapter + 1) / \(session.document.boundaries.count)") { showsContents = true }
                            Spacer()
                            Button("下一章") { move(1) }.disabled(chapter + 1 == session.document.boundaries.count)
                        }.padding()
                        HStack {
                            Button("设为章节标题") { setTitle() }.disabled(selection.length == 0)
                            Spacer()
                            Button("删除章节", role: .destructive) { confirmsDelete = true }.disabled(chapter == 0)
                        }.padding().background(.regularMaterial)
                    }
                } else if let error {
                    VStack(spacing: 16) {
                        Text(error)
                        Button("重试") { Task { await load() } }
                    }.padding()
                } else { ProgressView("正在准备原文…") }
            }
            .disabled(isSaving)
            .navigationTitle("TXT分章调整")
            .navigationBarTitleDisplayMode(.inline)
            .compatToolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("完成") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("撤销") { undoLast() }.disabled(undo.isEmpty || isSaving)
                }
            }
            .confirmationDialog("删除章节并合并到上一章？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除章节并合并到上一章", role: .destructive) { removeChapter() }
                Button("取消", role: .cancel) {}
            } message: { Text("原标题和正文会保留为上一章的内容。") }
            .alert("分章调整", isPresented: Binding(get: { error != nil && session != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sheet(isPresented: $showsContents) {
                CompatNavigationStack {
                    List {
                        if let session {
                            ForEach(session.document.boundaries.indices, id: \.self) { index in
                                Button(session.document.boundaries[index].title) {
                                    chapter = index; textPage = 0; selection = NSRange(location: NSNotFound, length: 0); showsContents = false
                                }
                            }
                        }
                    }.navigationTitle("章节目录")
                    .toolbar { ToolbarItem(placement: .compatTopBarTrailing) { Button("完成") { showsContents = false } } }
                }
            }
            .task { await load() }
            .onDisappear { if didSave { onSaved() } }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func load() async {
        error = nil
        do {
            let loaded = try await settings.txtAdjustments.session(url: url, rules: rules)
            guard !Task.isCancelled else { return }
            session = loaded
            let book = try await settings.txtBook(url: url, rules: rules, trace: DiagnosticContext.newTraceID())
            let position = settings.positions.txtPosition(hash: book.contentHash)
            let projection = settings.projection
            let map = try await Task.detached(priority: .userInitiated) {
                try TXTAdjustmentCoordinates(text: loaded.document.text, chapters: book.chapters, projection: projection)
            }.value
            let unit = position?.unit.flatMap { position?.unitCount == map.units.count && map.units.indices.contains($0) ? $0 : nil }
                ?? map.units.firstIndex(where: { $0.chapter == (position?.chapter ?? 0) }) ?? 0
            let raw = map.rawOffset(unit: unit, offset: position?.offset ?? 0) ?? 0
            chapter = loaded.document.chapter(containing: raw)
            textPage = max(0, (raw - loaded.document.boundaries[chapter].start) / 12_000)

        } catch { self.error = error.localizedDescription }
    }

    private func move(_ delta: Int) {
        chapter += delta; textPage = 0; selection = NSRange(location: NSNotFound, length: 0)
    }

    private func setTitle() {
        guard let session else { return }
        var next = session.document
        let region = visibleRange(next)
        do {
            guard selection.location != NSNotFound, selection.length <= region.length,
                  selection.location <= region.length - selection.length else { throw TXTAdjustmentError.invalidSelection }
            let range = NSRange(location: region.location + selection.location, length: selection.length)
            try next.setTitle(selection: range)
            save(next, focus: range.location)
        } catch { self.error = error.localizedDescription }
    }

    private func removeChapter() {
        guard let session else { return }
        var next = session.document
        do {
            let focus = next.boundaries[chapter].start
            try next.removeChapter(chapter)
            save(next, focus: focus)
        } catch { self.error = error.localizedDescription }
    }

    private func undoLast() {
        guard let previous = undo.last else { return }
        save(previous, focus: session?.document.boundaries[chapter].start ?? 0, isUndo: true)
    }

    private func save(_ next: TXTAdjustmentDocument, focus: Int, isUndo: Bool = false) {
        guard let session, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            var committedRevision: String?
            do {
                let oldBook = try await settings.txtBook(url: url, rules: rules, trace: DiagnosticContext.newTraceID())
                guard oldBook.contentHash == session.baseBook.contentHash else { throw TXTAdjustmentError.invalidDirectory }
                let migration = try await TXTAdjustmentMigration.prepare(oldBook: oldBook, next: next, settings: settings)
                let revision = try await settings.txtAdjustments.save(next, hash: oldBook.contentHash,
                    expectedRevision: session.revision, position: migration.position, bookmarks: migration.bookmarks)
                committedRevision = revision
                settings.invalidateTXTBook(hash: oldBook.contentHash)
                // 目录与迁移快照已经一起原子保存；失败时重新打开可重放，不能覆盖后来新写的状态。
                try settings.applyTXTAdjustment(migration, hash: oldBook.contentHash)
                if isUndo { _ = undo.popLast() } else { undo.append(session.document) }
                self.session?.document = next; self.session?.revision = revision
                chapter = next.chapter(containing: focus)
                textPage = max(0, (focus - next.boundaries[chapter].start) / 12_000)
                selection = NSRange(location: NSNotFound, length: 0)
                didSave = true
            } catch {
                // 原子提交后承接失败也必须刷新，后续重放不能再把旧目录当成当前目录。
                if let committedRevision {
                    self.session?.document = next; self.session?.revision = committedRevision
                    chapter = next.chapter(containing: focus); textPage = 0; didSave = true
                }
                self.error = error.localizedDescription
            }
        }
    }
}

/// 只读 UITextView 提供系统精确选区；一次仅装载当前章节的一段原文。
private struct TXTAdjustmentSelectionView: UIViewRepresentable {
    let text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        view.delegate = context.coordinator
        view.accessibilityLabel = "分章调整原文"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text; view.setContentOffset(.zero, animated: false) }
        if selection.length == 0, view.selectedRange.length != 0 { view.selectedRange = NSRange(location: 0, length: 0) }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TXTAdjustmentSelectionView
        init(_ parent: TXTAdjustmentSelectionView) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let value = textView.selectedRange
            if parent.selection != value { parent.selection = value }
        }
    }
}
