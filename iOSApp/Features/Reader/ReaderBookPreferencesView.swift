import SwiftUI

/// 本书文字转换与替换入口；不控制阅读样式的作用范围。
struct ReaderBookPreferencesView: View {
    @EnvironmentObject private var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ReadingTextProjection()
    @State private var source = ""
    @State private var replacement = ""
    private enum RuleField: Hashable { case source, replacement }
    @FocusState private var editingRule: RuleField?
    var body: some View {
        CompatNavigationStack {
            Form {
                Section("文字显示") {
                    Picker("简繁转换", selection: $draft.chinese) {
                        ForEach(ReadingTextProjection.Chinese.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("启用本书文字替换", isOn: $draft.enabled)
                }
                Section("添加替换规则") {
                    TextField("原词，例如人名", text: $source).focused($editingRule, equals: .source)
                        .submitLabel(.next).onSubmit { editingRule = .replacement }
                    TextField("替换为（可留空）", text: $replacement).focused($editingRule, equals: .replacement)
                        .submitLabel(.done).onSubmit { editingRule = nil }
                    Button("添加或更新") {
                        draft.replacements[source] = replacement; source = ""; replacement = ""; editingRule = nil
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
                    Text("先简繁转换，再按最长词优先替换一次；不改原文件。应用时重新排版。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("效果预览") { Text(draft.apply(source.isEmpty ? "这是本书的文字预览，閱讀偏好只影响显示。" : source)) }
            }
            .navigationTitle("本书文字处理")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("关闭") { dismiss() }
                    Spacer()
                    Button("应用") { settings.setProjection(draft); dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding().background(.regularMaterial)
            }
            .onAppear { draft = settings.projection }
        }
    }
}

/// 样式作用范围属于阅读设置，文字规则始终与本书绑定。
struct ReaderBookStyleScopeSection: View {
    @EnvironmentObject private var settings: ReaderSettings
    var onChange: () -> Void = {}
    var body: some View {
        Section {
            Toggle("本书使用独立样式", isOn: Binding(get: { settings.usesBookPreferences }, set: {
                settings.setBookPreferencesEnabled($0); onChange()
            }))
        } header: { Text("样式作用范围") } footer: {
            Text("开启后，字号、主题和排版只用于本书；关闭后继承全局设置。背景资源沿用全局。本书文字处理规则独立保存，不受此开关影响。")
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
