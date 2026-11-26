import SwiftUI

/// 收敛低频阅读与书库行为开关，保持「我的」首屏简洁，并沿用统一纸面卡片风格。
struct MoreReadingSettingsView: View {
    @AppStorage(SettingsKey.libraryAutoReadingStatus) private var autoReadingStatus = false
    @AppStorage(SettingsKey.libraryAutoOnHoldDays) private var autoOnHoldDays = 30
    @AppStorage(SettingsKey.libraryAutoInspectEPUBOnImport) private var autoInspectEPUBOnImport = true
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var epubUsesReadium = false
    #endif
    @AppStorage(SettingsKey.readerEPUBDisablesScripts) private var epubDisablesScripts = false
    @AppStorage(SettingsKey.readerBookBackgroundFollow) private var bookBackgroundFollow = ReaderBookBackgroundFollow.default.rawValue

    private var onHoldDaysLabel: String {
        autoOnHoldDays == 0 ? "关闭" : "\(autoOnHoldDays) 天"
    }

    private var currentBackgroundFollow: ReaderBookBackgroundFollow {
        ReaderBookBackgroundFollow(storedValue: bookBackgroundFollow)
    }

    @ViewBuilder
    private var readiumExperienceControls: some View {
        MeToggleRow(
            title: "禁用书内脚本",
            subtitle: "Readium 打开 EPUB 时不执行书籍自带脚本（如自绘注释气泡），改用统一注释弹层；原生引擎始终不执行。下次打开书籍时生效。",
            systemImage: "hand.raised",
            iconTint: Color.orange,
            isOn: $epubDisablesScripts
        )

        MeRowDivider()

        HStack(spacing: 12) {
            MeIconBadge(systemImage: "photo.on.rectangle.angled", tint: Color.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("书页底色与阅读背景")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink)
                Text("控制书籍原有白底与阅读背景的叠加方式")
                    .font(NoveliaStyle.fontCaption)
                    .foregroundStyle(NoveliaStyle.muted)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("书页底色与阅读背景", selection: Binding(
                    get: { currentBackgroundFollow },
                    set: { bookBackgroundFollow = $0.rawValue }
                )) {
                    ForEach(ReaderBookBackgroundFollow.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentBackgroundFollow.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MeCardSection(title: "文本与导入") {
                    NavigationLink {
                        TXTChapterRulesView()
                    } label: {
                        MeNavigationRow(
                            title: "TXT 分章规则",
                            subtitle: "管理内置与自定义正则分章匹配",
                            systemImage: "text.alignleft",
                            iconTint: Color.blue
                        )
                    }
                    .buttonStyle(.plain)

                    MeRowDivider()

                    MeToggleRow(
                        title: "入库时检测 EPUB 结构问题",
                        subtitle: "导入本地或首次下载 EPUB 时执行轻量体检（不解压正文），发现问题可修复、原样入库或跳过。",
                        systemImage: "checkmark.shield",
                        iconTint: Color.orange,
                        isOn: $autoInspectEPUBOnImport
                    )
                }

                MeCardSection(title: "书库状态") {
                    MeToggleRow(
                        title: "自动识别阅读状态",
                        subtitle: "新书自动归入「想读」，开始阅读转为「在读」，读到 98% 以上转为「读过」；手动标为「抛弃」的书不会被覆盖。",
                        systemImage: "wand.and.stars",
                        iconTint: NoveliaStyle.brandGreen,
                        isOn: $autoReadingStatus
                    )

                    if autoReadingStatus {
                        MeRowDivider()

                        HStack(spacing: 12) {
                            MeIconBadge(systemImage: "pause.circle", tint: Color.purple)
                            Text("久未阅读自动搁置")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(NoveliaStyle.ink)
                            Spacer(minLength: 8)
                            Menu {
                                Picker("久未阅读自动搁置", selection: $autoOnHoldDays) {
                                    Text("关闭").tag(0)
                                    Text("30 天").tag(30)
                                    Text("60 天").tag(60)
                                    Text("90 天").tag(90)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(onHoldDaysLabel)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(autoOnHoldDays == 0 ? NoveliaStyle.muted : NoveliaStyle.brandGreen)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }

                MeCardSection(title: "分页引擎") {
                    #if NOVELIA_READIUM_ONLY
                    readiumExperienceControls
                    #else
                    MeToggleRow(
                        title: "分页使用 Readium 引擎（实验）",
                        subtitle: "适用于 EPUB、TXT 和在线小说的分页阅读；关闭后使用原生分页引擎。下次打开阅读器时生效。",
                        systemImage: "book.pages",
                        iconTint: Color.indigo,
                        isOn: $epubUsesReadium
                    )
                    if epubUsesReadium {
                        MeRowDivider()
                        readiumExperienceControls
                    }
                    #endif
                }

                #if NOVELIA_READIUM_ONLY
                MeSectionFooter(text: "“忽略白色底色”会将白/米白页底透明化以透出阅读背景，保留彩色底与书内背景图；“保留背景图片”在设置背景图时边距不跟随书页。")
                #else
                if epubUsesReadium {
                    MeSectionFooter(text: "“忽略白色底色”会将白/米白页底透明化以透出阅读背景，保留彩色底与书内背景图；“保留背景图片”在设置背景图时边距不跟随书页。")
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("更多阅读与书库设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TXTChapterRulesView: View {
    @StateObject private var ruleStore = TXTChapterRuleStore.shared
    @State private var isShowingEditor = false
    @State private var editingRule: TXTChapterRule?

    private var builtInRules: [TXTChapterRule] { ruleStore.rules.filter(\.isBuiltIn) }
    private var customRules: [TXTChapterRule] { ruleStore.rules.filter { !$0.isBuiltIn } }

    var body: some View {
        Form {
            Section {
                Text("规则按行匹配。关闭某条规则后，TXT 阅读器会忽略对应格式；自定义规则需匹配整行，并建议使用 ^ 和 $ 限定边界。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("内置规则") {
                ForEach(builtInRules) { rule in
                    ruleRow(rule, editable: false)
                }
            }
            Section {
                if customRules.isEmpty {
                    Text("还没有自定义规则。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(customRules) { rule in
                    ruleRow(rule, editable: true)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                ruleStore.deleteCustomRule(rule)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
                Button {
                    editingRule = nil
                    isShowingEditor = true
                } label: {
                    Label("添加自定义规则", systemImage: "plus")
                }
            } header: {
                Text("自定义规则")
            } footer: {
                Text("自定义正则只检查整行。启用后重新打开 TXT，即可按新规则生成章节目录。")
            }
            Section("分章保护") {
                Text("标题还会经过行长、句末标点、开头目录和编号顺序检查。若最终识别出的章节少于 3 个，阅读器会保留全文，不进行猜测切分。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TXT 分章规则")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingEditor) {
            TXTChapterRuleEditor(rule: editingRule) { rule in
                ruleStore.saveCustomRule(rule)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: TXTChapterRule, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                if editable {
                    Button {
                        editingRule = rule
                        isShowingEditor = true
                    } label: {
                        Text(rule.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(rule.name)
                        .font(.system(size: 15, weight: .semibold))
                }
                Toggle("启用", isOn: Binding(
                    get: { ruleStore.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                    set: { ruleStore.setEnabled($0, for: rule.id) }
                ))
                .labelsHidden()
            }
            Text(rule.explanation)
                .font(NoveliaStyle.fontFootnote)
                .foregroundStyle(.secondary)
            Text(rule.pattern)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct TXTChapterRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let originalRule: TXTChapterRule?
    let onSave: (TXTChapterRule) -> Void
    @State private var name: String
    @State private var pattern: String
    @State private var errorMessage: String?

    init(rule: TXTChapterRule?, onSave: @escaping (TXTChapterRule) -> Void) {
        originalRule = rule
        self.onSave = onSave
        _name = State(initialValue: rule?.name ?? "")
        _pattern = State(initialValue: rule?.pattern ?? "")
    }

    var body: some View {
        CompatNavigationStack {
            Form {
                Section("规则名称") {
                    TextField("例如：自定义章节格式", text: $name)
                }
                Section("整行正则表达式") {
                    CompatVerticalTextField(prompt: #"例如：^第\d+节.*$"#, text: $pattern, limit: 2...5)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .compatAutocorrectionDisabled()
                    Text("使用系统正则语法。规则必须匹配整行；推荐以 ^ 开始、以 $ 结束。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(NoveliaStyle.danger)
                    }
                }
            }
            .navigationTitle(originalRule == nil ? "新建分章规则" : "编辑分章规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .compatTopBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .compatTopBarTrailing) {
                    Button("保存") { save() }
                        .compatFontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "请填写规则名称。"
            return
        }
        guard !cleanPattern.isEmpty else {
            errorMessage = "请填写正则表达式。"
            return
        }
        guard (try? NSRegularExpression(pattern: cleanPattern)) != nil else {
            errorMessage = "正则表达式格式无效，请检查括号、方括号和转义符。"
            return
        }
        let rule = TXTChapterRule(
            id: originalRule?.id ?? UUID().uuidString,
            name: cleanName,
            pattern: cleanPattern,
            explanation: "用户自定义规则。",
            isEnabled: originalRule?.isEnabled ?? true,
            isBuiltIn: false
        )
        onSave(rule)
        dismiss()
    }
}
