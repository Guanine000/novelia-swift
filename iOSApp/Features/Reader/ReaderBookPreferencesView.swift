import SwiftUI

/// 当前阅读会话的单书偏好入口。转换和规则由用户点击应用后一起生效。
struct ReaderBookPreferencesView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ReadingTextProjection()
    @State private var source = ""
    @State private var replacement = ""
    @FocusState private var editingRule: Bool
    var body: some View {
        CompatNavigationStack {
            Form {
                Section {
                    Toggle("仅应用于这本书", isOn: Binding(get: { settings.usesBookPreferences }, set: { settings.setBookPreferencesEnabled($0) }))
                } footer: { Text("单书保存字号、主题、分页与排版。关闭后重新继承全局默认；不会改动其他书籍。文字转换与替换规则只属于本书。") }
                Section("文字显示") {
                    Picker("简繁转换", selection: $draft.chinese) {
                        ForEach(ReadingTextProjection.Chinese.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("启用本书文字替换", isOn: $draft.enabled)
                }
                Section("添加替换规则") {
                    TextField("原词，例如人名", text: $source).focused($editingRule)
                    TextField("替换为（可留空）", text: $replacement).focused($editingRule)
                    Button("添加或更新") {
                        draft.replacements[source] = replacement; source = ""; replacement = ""; editingRule = false
                    }
                    .disabled(source.isEmpty || source.utf16.count > 120 || replacement.utf16.count > 120 || draft.replacements.count >= 1000)
                }
                Section("本书规则") {
                    ForEach(draft.replacements.keys.sorted(), id: \.self) { key in
                        HStack { Text(key); Image(systemName: "arrow.right"); Text(draft.replacements[key] ?? ""); Spacer() }
                            .contentShape(Rectangle())
                            .onTapGesture { source = key; replacement = draft.replacements[key] ?? "" }
                            .swipeActions { Button("删除", role: .destructive) { draft.replacements[key] = nil } }
                    }
                    Text("先简繁转换，再按最长词优先替换一次；不改原文件。应用时暂停朗读并重新排版。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("效果预览") { Text(draft.apply(source.isEmpty ? "这是本书的文字预览，閱讀偏好只影响显示。" : source)) }
            }
            .navigationTitle("单书阅读偏好")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") { settings.setProjection(draft); dismiss() } }
            }
            .onAppear { draft = settings.projection }
        }
    }
}

struct ReaderSearchRangeKey: EnvironmentKey { static let defaultValue: Range<Int>? = nil }
extension EnvironmentValues {
    var readerSearchRange: Range<Int>? { get { self[ReaderSearchRangeKey.self] } set { self[ReaderSearchRangeKey.self] = newValue } }
}
struct ReaderScrollFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
    static func visible(_ frames: [String: CGRect]) -> String? {
        frames.filter { $0.value.maxY > 100 }.min { $0.value.minY < $1.value.minY }?.key
    }
}
struct ScrollReadingReturnPoint { let chapter: Int; let anchor: String? }
