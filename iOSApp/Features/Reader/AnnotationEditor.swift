// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 新建笔记或编辑已有点击高亮的临时状态。原生分页与 Readium 共用。
struct AnnotationEditorTarget: Identifiable {
    let id = UUID()
    let range: NSRange?
    let quote: String
    let annotation: ReaderAnnotation?
}

/// 标注颜色与笔记编辑面板；保存/删除由宿主写回同一 ReaderAnnotationStore。
struct AnnotationEditorSheet: View {
    let target: AnnotationEditorTarget
    let onSave: (ReaderAnnotation.Color, String) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var color: ReaderAnnotation.Color
    @State private var note: String

    init(target: AnnotationEditorTarget, onSave: @escaping (ReaderAnnotation.Color, String) -> Void,
         onDelete: (() -> Void)?) {
        self.target = target
        self.onSave = onSave
        self.onDelete = onDelete
        _color = State(initialValue: target.annotation?.color ?? .yellow)
        _note = State(initialValue: target.annotation?.note ?? "")
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    Text(target.quote).font(.body)
                }
                Section("颜色") {
                    Picker("颜色", selection: $color) {
                        ForEach(ReaderAnnotation.Color.allCases, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                }
                Section("笔记") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(target.annotation == nil ? "添加笔记" : "编辑标注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(color, note); dismiss() }
                }
                if let onDelete {
                    ToolbarItem(placement: .bottomBar) {
                        Button("删除标注", role: .destructive) { onDelete(); dismiss() }
                    }
                }
            }
        }
    }
}

extension ReaderAnnotation.Color {
    var swiftUIColor: Color {
        switch self {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }

    var uiColor: UIColor {
        switch self {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemPink
        case .purple: .systemPurple
        }
    }
}
