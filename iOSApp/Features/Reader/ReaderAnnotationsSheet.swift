// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 一本书的摘录与笔记列表。原生分页与 Readium 共用；点按跳到原文，左滑删除，可导出 Markdown。
struct ReaderAnnotationsSheet: View {
    @ObservedObject var store: ReaderAnnotationStore
    let bookKey: String
    let bookTitle: String
    let chapterTitle: (Int) -> String?
    let onJump: (ReaderAnnotation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ReaderAnnotation?

    private var annotations: [ReaderAnnotation] {
        store.annotations(for: bookKey)
    }

    private var groups: [(chapter: Int, items: [ReaderAnnotation])] {
        var result: [(chapter: Int, items: [ReaderAnnotation])] = []
        for annotation in annotations {
            if let last = result.last, last.chapter == annotation.chapterIndex {
                result[result.count - 1].items.append(annotation)
            } else {
                result.append((annotation.chapterIndex, [annotation]))
            }
        }
        return result
    }

    var body: some View {
        CompatNavigationStack {
            Group {
                if annotations.isEmpty {
                    CompatUnavailable {
                        Label("还没有摘录", systemImage: "highlighter")
                    } description: {
                        Text("在分页阅读中选中文字，点「高亮」或「添加笔记」。")
                    } actions: {
                        EmptyView()
                    }
                } else {
                    List {
                        ForEach(groups, id: \.chapter) { group in
                            Section(chapterTitle(group.chapter) ?? "第 \(group.chapter + 1) 章") {
                                ForEach(group.items) { annotation in
                                    row(annotation)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("摘录与笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                if !annotations.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        CompatShareTextLink(text: markdown) {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .confirmationDialog("删除这条摘录？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let annotation = pendingDelete { try? store.remove(annotation.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private func row(_ annotation: ReaderAnnotation) -> some View {
        Button {
            dismiss()
            onJump(annotation)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(annotation.color.swiftUIColor)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(annotation.quote)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    if !annotation.note.isEmpty {
                        Text(annotation.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Text(annotation.createdAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = annotation } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var markdown: String {
        var lines = ["# \(bookTitle)", ""]
        for annotation in annotations {
            lines.append("## \(chapterTitle(annotation.chapterIndex) ?? "第 \(annotation.chapterIndex + 1) 章")")
            lines.append("")
            lines.append("> \(annotation.quote.replacingOccurrences(of: "\n", with: "\n> "))")
            lines.append("")
            if !annotation.note.isEmpty {
                lines.append(annotation.note)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
