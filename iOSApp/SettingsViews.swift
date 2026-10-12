import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @EnvironmentObject private var auth: AccountAuthStore
    @AppStorage(SettingsKey.appThemeColor) private var themeColorRaw = AppThemeColor.novelia.rawValue
    @AppStorage(SettingsKey.appThemeCustomHex) private var themeCustomHex = "559775"
    @ObservedObject private var readerSettings = ReaderSettings.shared
    @AppStorage(SettingsKey.readerMode) private var modeRaw = ReaderMode.bilingual.rawValue
    @State private var isExportingLogs = false
    @State private var isShowingLogShare = false
    @State private var logFileURL: URL?
    @State private var logExportError: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var selectedMode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .bilingual
    }

    var body: some View {
        Form {
            Section("Novelia 账号") {
                if let username = auth.username {
                    LabeledContent("已登录", value: username)
                    Button("退出登录", role: .destructive) { auth.logout() }
                } else {
                    Text("登录后可使用需要账号的服务。密码由 Novelia 认证网页处理，App 只保存会话令牌。")
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                    Button {
                        auth.errorMessage = nil
                        auth.isLoginPresented = true
                    } label: {
                        Label("登录 / 注册", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .tint(NoveliaStyle.brandGreen)
                }
            }
            Section("内容筛选") {
                NavigationLink("标签屏蔽") { BlockedTagsView() }
            }
            Section("阅读体验") {
                NavigationLink("阅读背景") { ReaderBackgroundSettingsView() }
                Picker(selection: $themeColorRaw) {
                    ForEach(AppThemeColor.allCases) { option in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(option == .custom ? AppThemeColor.color(fromHex: themeCustomHex) : option.color)
                                .frame(width: 12, height: 12)
                            Text(option.title)
                        }
                        .tag(option.rawValue)
                    }
                } label: {
                    Label("主题色", systemImage: "paintpalette")
                }
                if AppThemeColor(rawValue: themeColorRaw) == .custom {
                    ColorPicker(
                        "自定义颜色",
                        selection: Binding(
                            get: { AppThemeColor.color(fromHex: themeCustomHex) },
                            set: { themeCustomHex = AppThemeColor.hex(from: $0) }
                        ),
                        supportsOpacity: false
                    )
                }
                Picker("显示语言", selection: $modeRaw) {
                    ForEach(ReaderMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("正文字号")
                        Spacer()
                        Text("\(Int(readerSettings.fontSize)) pt")
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    Slider(value: $readerSettings.fontSize, in: ReaderSettings.fontRange, step: 1)
                        .tint(NoveliaStyle.brandGreen)
                }
                NavigationLink {
                    TXTChapterRulesView()
                } label: {
                    Label("TXT 分章规则", systemImage: "text.alignleft")
                }
            }
            Section("下载") {
                NavigationLink {
                    MyDownloadsView()
                } label: {
                    Label("我的下载", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    WebDAVSyncView()
                } label: {
                    Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Section("版本") {
                Toggle("启动时检查更新", isOn: $checksUpdates)
                LabeledContent("当前版本", value: appVersion)
                LabeledContent("平台", value: "iOS 17+")
                NavigationLink("开源许可") {
                    ThirdPartyLicensesView()
                }
            }
            Section("诊断") {
                Button {
                    exportLogs()
                } label: {
                    if isExportingLogs {
                        Label("正在准备日志…", systemImage: "hourglass")
                    } else {
                        Label("导出应用日志", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExportingLogs)
                Text("导出本应用最近 7 天内当前运行可读取的诊断事件，仅保留错误码、耗时和数量等信息，省略标识符、文件路径和未经审查的文本。")
                    .font(.system(size: 13))
                    .foregroundStyle(NoveliaStyle.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NoveliaStyle.paper)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingLogShare) {
            if let logFileURL {
                LogActivitySheet(activityItems: [logFileURL])
            }
        }
        .alert("无法导出日志", isPresented: Binding(
            get: { logExportError != nil },
            set: { if !$0 { logExportError = nil } }
        )) {
            Button("好", role: .cancel) { logExportError = nil }
        } message: {
            Text(logExportError ?? "")
        }
    }

    private func exportLogs() {
        guard !isExportingLogs else { return }
        isExportingLogs = true
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ApplicationLogExporter.makeFile()
                }.value
                logFileURL = url
                isShowingLogShare = true
            } catch {
                logExportError = error.localizedDescription
            }
            isExportingLogs = false
        }
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
                .font(.system(size: 12))
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
        NavigationStack {
            Form {
                Section("规则名称") {
                    TextField("例如：自定义章节格式", text: $name)
                }
                Section("整行正则表达式") {
                    TextField(#"例如：^第\d+节.*$"#, text: $pattern, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("使用系统正则语法。规则必须匹配整行；推荐以 ^ 开始、以 $ 结束。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(originalRule == nil ? "新建分章规则" : "编辑分章规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
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

private enum ApplicationLogExporter {
    static func makeFile() throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let entries = try store.getEntries(at: store.position(date: startDate))
        let logEntries = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.subsystem == ShareableLogPolicy.subsystem }
        let now = Date()
        let exported = logEntries.compactMap { entry -> ShareableLogLine? in
            guard let message = ShareableLogPolicy.message(
                subsystem: entry.subsystem, category: entry.category, text: entry.composedMessage
            ) else { return nil }
            return ShareableLogLine(secondsAgo: max(0, Int(now.timeIntervalSince(entry.date))),
                                    level: levelName(entry.level), category: entry.category, message: message)
        }
        // Fold repeats before the line cap so a burst cannot push out older events.
        let collapsed = ShareableLogAggregator.collapse(exported)
        let messages = Array(collapsed.suffix(5_000))
        let txtDiagnosticCount = logEntries.filter { $0.category == "txt" }.count
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        var lines = [
            "Novelia iOS 应用诊断日志（隐私过滤版）",
            "版本：\(version) (\(build))",
            "范围：最近 7 天当前进程日志，连续重复事件合并为一行并标注 (×次数)，最多 5000 行",
            "读取的应用事件：\(logEntries.count)；通过隐私过滤：\(exported.count)；合并后行数：\(collapsed.count)",
            "省略未经审查的应用事件：\(logEntries.count - exported.count)",
            "不包含系统／框架日志；仅导出已审查的诊断格式，时间为距导出时的秒数。",
            "已读取的 TXT 导入 / 解码 / 分章事件数：\(txtDiagnosticCount)",
            ""
        ]
        lines.append(contentsOf: messages.isEmpty ? ["没有符合隐私过滤规则的应用诊断事件。"] : messages)

        let filename = "Novelia-shareable-logs.txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }
}

private struct LogActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ThirdPartyLicensesView: View {
    private let packages: [(name: String, version: String, license: String, file: String)] = [
        ("SwiftSoup", "2.13.7", "MIT", "SwiftSoup-LICENSE.txt"),
        ("YueduCoreText", "0.8.0", "MPL-2.0", "YueduCoreText-LICENSE.txt"),
        ("ZIPFoundation", "3.0.1", "MIT", "ZIPFoundation-LICENSE.txt")
    ]

    var body: some View {
        List {
            Section("本应用") {
                Text("本项目自有源代码和项目文档采用 GNU GPL-3.0-only。该许可允许用户复制、修改和再分发；本软件不提供任何担保。")
                NavigationLink("GNU GPL-3.0-only 完整文本") {
                    licenseText("GPL-3.0-only.txt", title: "GNU GPL-3.0-only")
                }
                Text("本项目是参考 GPL-3.0-only 安卓客户端 nobYoQ/novelia 制作的 Swift iOS 移植版本，包含 iOS 平台实现及后续修改。上游版权声明：Copyright (C) 2026 Novelia Android contributors. 本 iOS 移植及新增部分：Copyright (C) 2026 Novelia iOS contributors。修改版本日期：2026-10-10。")
                Link("查看对应版本的源码仓库", destination: URL(string: "https://github.com/Guanine000/novelia-swift")!)
                Text("源码仓库公开可访问。Release 同时提供对应版本的完整源码及第三方许可材料。")
            }
            Section {
                Text("本应用使用的第三方软件及其原始许可文本。YueduCoreText 的 NOTICE 包含 Unicode License v3。")
            }
            Section("依赖") {
                ForEach(packages, id: \.name) { package in
                    NavigationLink {
                        licenseText(package.file, title: package.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(package.name)
                            Text("\(package.version) · \(package.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("附加声明") {
                NavigationLink("YueduCoreText NOTICE / Unicode License v3") {
                    licenseText("YueduCoreText-NOTICE.txt", title: "附加声明")
                }
                Link("YueduCoreText 0.8.0 对应源码", destination: URL(string: "https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/783ce903d5faf4ff5d15c546e32a107537ba5efe")!)
            }
        }
        .navigationTitle("开源许可")
    }

    private func licenseText(_ file: String, title: String) -> some View {
        let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "ThirdPartyLicenses")
        let content = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return ScrollView {
            Text(content ?? "许可文件未找到：\(file)")
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
