import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

/// 收敛关于信息、更新开关、开源许可与诊断日志，采用统一纸面卡片风格。
struct AboutAndDiagnosticsView: View {
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @AppStorage(ReaderDebugOptions.showsTOCDiagnosticsKey) private var showsTOCDiagnostics = false
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var epubUsesReadium = false
    #endif
    @EnvironmentObject private var services: AppServices
    @State private var isExportingLogs = false
    @State private var isShowingLogShare = false
    @State private var logFileURL: URL?
    @State private var logExportError: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var platformText: String {
        #if NOVELIA_READIUM_ONLY
        return "iOS 15+"
        #else
        return "iOS 17+"
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [NoveliaStyle.brandGreen, NoveliaStyle.brandGreen.opacity(0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Novelia")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(NoveliaStyle.ink)
                        HStack(spacing: 8) {
                            Text("版本 \(appVersion)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(NoveliaStyle.muted)
                            Text(platformText)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)

                MeCardSection(title: "更新与许可") {
                    MeToggleRow(
                        title: "启动时检查更新",
                        systemImage: "sparkles.rectangle.stack",
                        iconTint: NoveliaStyle.brandGreen,
                        isOn: $checksUpdates
                    )

                    MeRowDivider()

                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        MeNavigationRow(
                            title: "开源许可",
                            subtitle: "GPL-3.0 与第三方组件声明",
                            systemImage: "doc.plaintext",
                            iconTint: Color.teal
                        )
                    }
                    .buttonStyle(.plain)
                }

                MeCardSection(title: "诊断与日志") {
                    MeToggleRow(
                        title: "显示目录诊断信息",
                        subtitle: "在目录中显示书籍结构解析说明、章节 spine 编号与诊断提示。排查排版问题时打开，平时保持关闭。",
                        systemImage: "stethoscope",
                        iconTint: Color.orange,
                        isOn: $showsTOCDiagnostics
                    )

                    MeRowDivider()

                    Button {
                        exportLogs()
                    } label: {
                        MeNavigationRow(
                            title: isExportingLogs ? "正在准备日志…" : "导出应用日志",
                            systemImage: isExportingLogs ? "hourglass" : "square.and.arrow.up",
                            iconTint: NoveliaStyle.brandGreen,
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExportingLogs)
                }

                MeSectionFooter(text: "导出本应用最近 7 天内当前运行可读取的诊断事件，仅保留错误码、耗时和数量等信息，省略标识符、文件路径和未经审查的文本。")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("关于、许可与诊断")
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
        #if NOVELIA_READIUM_ONLY
        let readerEngine = "readium (legacy)"
        #else
        let readerEngine = epubUsesReadium ? "readium" : "native"
        #endif
        let aiConfig = services.readingAI.configuration
        let summary = ApplicationLogExporter.EnvironmentSummary(
            readerEngine: readerEngine,
            webDAVEnabled: services.local.sync.isEnabled,
            aiEnabled: aiConfig.isEnabled,
            aiFormat: aiConfig.requestFormat.rawValue
        )
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ApplicationLogExporter.makeFile(summary: summary)
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

private enum ApplicationLogExporter {
    struct EnvironmentSummary: Sendable {
        let readerEngine: String
        let webDAVEnabled: Bool
        let aiEnabled: Bool
        let aiFormat: String
    }

    static func makeFile(summary: EnvironmentSummary) throws -> URL {
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        let now = Date()
        let journal = DiagnosticJournal.shared
        journal.flush()
        let logEntries: [OSLogEntryLog]
        let persistedEntries: [DiagnosticJournalEntry]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: startDate))
            logEntries = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.subsystem == ShareableLogPolicy.subsystem }
            // OSLogStore 成功时，当前启动从系统日志读取，持久化文件只补充以前启动，避免重复。
            // 但空结果通常表示当前进程日志不可见；此时改用 journal，避免导出空日志。
            persistedEntries = logEntries.isEmpty
                ? journal.entries(since: startDate)
                : journal.entries(since: startDate, excludingLaunch: journal.launch)
        } catch {
            // 系统日志权限、容器状态或 OSLogStore 初始化失败时，持久化文件仍是完整的分享来源。
            logEntries = []
            persistedEntries = journal.entries(since: startDate)
        }
        var launchSections: [(label: String, lines: [ShareableLogLine])] = []
        for entry in persistedEntries {
            let line = ShareableLogLine(secondsAgo: max(0, Int(now.timeIntervalSince(entry.date))),
                                        level: entry.level, category: entry.category, message: entry.message)
            let label = "Launch \(entry.launch) (\(entry.launch == journal.launch ? "current" : "previous"))"
            if launchSections.last?.label == label {
                launchSections[launchSections.count - 1].lines.append(line)
            } else {
                launchSections.append((label: label, lines: [line]))
            }
        }
        let current = logEntries.compactMap { entry -> ShareableLogLine? in
            guard let message = ShareableLogPolicy.message(
                subsystem: entry.subsystem, category: entry.category, text: entry.composedMessage
            ) else { return nil }
            return ShareableLogLine(secondsAgo: max(0, Int(now.timeIntervalSince(entry.date))),
                                    level: levelName(entry.level), category: entry.category, message: message)
        }
        if !current.isEmpty {
            launchSections.append((label: "Launch \(journal.launch) (current)", lines: current))
        }
        // 按分类分配有界预算后，再按启动批次分段并合并连续重复记录。
        let bounded = boundedSections(launchSections, maxLines: 10_000, reservedPerCategory: 100)
        let messages = ShareableLogAggregator.collapseByLaunch(bounded)
        let txtDiagnosticCount = logEntries.filter { $0.category == "txt" }.count
            + persistedEntries.filter { $0.category == "txt" }.count
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        var lines = [
            "Novelia iOS 应用诊断日志（隐私过滤版）",
            "版本：\(version) (\(build))",
            "系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)（\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")）",
            "配置摘要：阅读引擎=\(summary.readerEngine)，WebDAV=\(summary.webDAVEnabled ? "开启" : "关闭")，AI=\(summary.aiEnabled ? "开启(\(summary.aiFormat))" : "关闭")",
            "范围：最近 7 天；优先读取本次启动的系统日志并以 App 诊断文件补充以前启动；若系统日志不可读则全部从 App 诊断文件读取；按启动批次分段，连续重复事件合并为一行并标注 (×次数)",
            "持久化诊断记录：\(persistedEntries.count)",
            "本次启动读取的应用事件：\(logEntries.count)；通过隐私过滤：\(current.count)；有界折叠后行数：\(messages.count)",
            "省略未经审查的应用事件：\(logEntries.count - current.count)",
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

    /// 每个分类先保留最近的保底名额，剩余名额按全局新鲜度补齐，避免单一高频分类独占导出预算。
    private static func boundedSections(
        _ sections: [(label: String, lines: [ShareableLogLine])],
        maxLines: Int,
        reservedPerCategory: Int
    ) -> [(label: String, lines: [ShareableLogLine])] {
        let categories = sections.flatMap { $0.lines.map(\.category) }
        guard categories.count > maxLines else { return sections }
        let selected = ShareableLogBudget.selectedIndices(
            categories: categories, maxLines: maxLines, reservedPerCategory: reservedPerCategory
        )
        var flatIndex = 0
        return sections.compactMap { section in
            let lines = section.lines.compactMap { line -> ShareableLogLine? in
                defer { flatIndex += 1 }
                return selected.contains(flatIndex) ? line : nil
            }
            return lines.isEmpty ? nil : (label: section.label, lines: lines)
        }
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
    /// GPL-3.0 第 5(a) 条要求的修改日期。scripts/build_local_release.py 要求它等于
    /// 发布提交的日期，因此每次发布构建时都需更新。
    static let modifiedDate = "2026-11-26"
    /// iOS 15 目标不链接 YueduCoreText，开源许可页不将其列为本二进制的组件。
    private var packages: [(name: String, version: String, license: String, file: String)] {
        let all: [(name: String, version: String, license: String, file: String)] = [
            ("SwiftSoup", "2.13.7", "MIT", "SwiftSoup-LICENSE.txt"),
            ("YueduCoreText", "0.18.1", "MPL-2.0", "YueduCoreText-LICENSE.txt"),
            ("ZIPFoundation", "3.0.1", "MIT", "ZIPFoundation-LICENSE.txt"),
            ("Readium swift-toolkit", "3.11.0", "BSD-3-Clause", "swift-toolkit-LICENSE.txt"),
            ("CryptoSwift", "1.10.0", "CryptoSwift License", "CryptoSwift-LICENSE.txt"),
            ("DifferenceKit", "1.3.0", "Apache-2.0", "DifferenceKit-LICENSE.txt"),
            ("Fuzi", "4.0.1", "MIT", "Fuzi-LICENSE.txt"),
            ("GCDWebServer", "4.0.1", "BSD-3-Clause", "GCDWebServer-LICENSE.txt"),
            ("SQLite.swift", "0.16.0", "MIT", "SQLite.swift-LICENSE.txt"),
            ("Zip", "2.1.2", "MIT", "Zip-LICENSE.txt"),
            ("libmobi", "0.12", "LGPL-3.0-or-later", "libmobi-LICENSE.txt"),
            ("OpenCC 繁体词组表（派生）", "ver.1.4.2", "Apache-2.0", "OpenCC-LICENSE.txt")
        ]
        #if NOVELIA_READIUM_ONLY
        return all.filter { $0.name != "YueduCoreText" }
        #else
        return all
        #endif
    }
    /// 随 Readium 资源包一起分发的字体和脚本。
    private let readiumAssets: [(name: String, file: String)] = [
        ("ReadiumCSS 字体 AccessibleDfA（SIL OFL 1.1）", "ReadiumCSS-AccessibleDfA-LICENSE.txt"),
        ("ReadiumCSS 字体 iA Writer Duospace（SIL OFL 1.1）", "ReadiumCSS-iAWriterDuospace-LICENSE.txt"),
        ("OpenDyslexic 字体（Bitstream Vera / CC BY 3.0）", "OpenDyslexic-LICENSE.txt"),
        ("Readium 阅读器脚本中的第三方代码", "Readium-JavaScript-NOTICES.txt")
    ]

    var body: some View {
        List {
            Section("本应用") {
                Text("本项目自有源代码和项目文档采用 GNU GPL-3.0-only。该许可允许用户复制、修改和再分发；本软件不提供任何担保。")
                NavigationLink("GNU GPL-3.0-only 完整文本") {
                    licenseText("GPL-3.0-only.txt", title: "GNU GPL-3.0-only")
                }
                Text("本项目是参考 GPL-3.0-only 安卓客户端 nobYoQ/novelia 制作的 Swift iOS 移植版本，包含 iOS 平台实现及后续修改。上游版权声明：Copyright (C) 2026 Novelia Android contributors. 本 iOS 移植及新增部分：Copyright (C) 2026 Novelia iOS contributors。修改版本日期：\(Self.modifiedDate)。")
                Link("查看公开项目仓库", destination: URL(string: "https://github.com/Guanine000/novelia-swift")!)
                Text("对应源码及第三方许可材料由分发者随本构建提供，或在配套源码说明中注明下载地址。公开项目仓库可能不包含私密测试构建，请按安装包版本和构建号获取配套材料。")
            }
            Section {
                #if NOVELIA_READIUM_ONLY
                Text("本应用使用的第三方软件、数据及其原始许可文本。此 iOS 15 版本使用 Readium 分页，不包含 YueduCoreText。简繁词表为 OpenCC 词典的修改版本。")
                #else
                Text("本应用使用的第三方软件、数据及其原始许可文本。YueduCoreText 的 NOTICE 包含 Unicode License v3；简繁词表为 OpenCC 词典的修改版本。")
                #endif
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
                NavigationLink("NoveliaECH 原生传输库许可（Go / jissr-bypass）") {
                    licenseText("ECH-native.txt", title: "NoveliaECH 许可")
                }
                NavigationLink("Zip 内嵌 MiniZip / Info-ZIP 许可") {
                    licenseText("Zip-MiniZip-NOTICE.txt", title: "MiniZip / Info-ZIP")
                }
                #if !NOVELIA_READIUM_ONLY
                NavigationLink("YueduCoreText NOTICE / Unicode License v3") {
                    licenseText("YueduCoreText-NOTICE.txt", title: "附加声明")
                }
                Link("YueduCoreText 0.18.1 对应源码", destination: URL(string: "https://github.com/CHANG-JUI-LIN/YueduCoreText/tree/5cc346abddd5801fd82d10509bf7f78af5ec0d49")!)
                #endif
                Text("CryptoSwift 许可要求的致谢")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("This product includes software developed by the \"Marcin Krzyzanowski\" (http://krzyzanowskim.com/).")
                    .font(.footnote)
            }
            Section("Readium 随附字体与脚本") {
                ForEach(readiumAssets, id: \.file) { asset in
                    NavigationLink(asset.name) {
                        licenseText(asset.file, title: asset.name)
                    }
                }
            }
        }
        .navigationTitle("开源许可")
    }

    private func licenseText(_ file: String, title: String) -> some View {
        let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "ThirdPartyLicenses")
        let content = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return LicenseTextView(text: content ?? "许可文件未找到：\(file)")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 使用可滚动的文本视图渲染长许可证文档，避免单个 SwiftUI Text 过大。
private struct LicenseTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            view.setContentOffset(.zero, animated: false)
        }
    }
}
