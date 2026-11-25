import SwiftUI
import OSLog
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var updates: NoveliaUpdateStore
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var readerSettings: ReaderSettings
    @EnvironmentObject private var statistics: ReadingStatisticsStore
    @EnvironmentObject private var webDAVSync: WebDAVSyncStore
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var cloudBooks: CloudBookStore

    @State private var updateCheckMessage: String?
    @State private var isConfirmingLogout = false
    @AppStorage(SettingsKey.appThemeColor) private var themeColorRaw = AppThemeColor.novelia.rawValue
    @AppStorage(SettingsKey.appThemeCustomHex) private var themeCustomHex = "559775"
    @AppStorage(SettingsKey.appPaperStyle) private var paperStyleRaw = AppPaperStyle.gray.rawValue
    @AppStorage(SettingsKey.appDarkOLED) private var appDarkOLED = false
    @AppStorage(SettingsKey.readerMode) private var modeRaw = ReaderMode.bilingual.rawValue
    @AppStorage(SettingsKey.networkECHEnabled) private var echEnabled = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var selectedMode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .bilingual
    }

    private var libraryBookCount: Int {
        guard webDownloads.isReady, wenkuDownloads.isReady else { return 0 }
        let all = libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks)
        return libraryState.displayBooks(from: all).count
    }

    private var todayReadingText: String {
        let key = ReadingStatistics.dayKey(Date())
        return Self.compactDuration(statistics.statistics.seconds(days: [key]))
    }

    private var totalReadingText: String {
        Self.compactDuration(statistics.statistics.seconds())
    }

    private var streakDays: Int {
        statistics.statistics.streakDays(asOf: Date())
    }

    private var webDAVStatusText: String {
        if webDAVSync.isSyncing { return "正在同步…" }
        if !webDAVSync.isEnabled { return "未开启" }
        return webDAVSync.autoSyncEnabled ? "自动同步" : "已开启"
    }

    private var aiStatusText: String {
        services.readingAI.configuration.isEnabled ? "已开启" : "未开启"
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分钟" }
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours)h \(minutes)m"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                profileHeroCard
                quickHubGrid
                readingSection
                appearanceSection
                dataAndNetworkSection
                aboutSection
                footerView
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .alert("检查更新", isPresented: .init(get: { updateCheckMessage != nil }, set: { if !$0 { updateCheckMessage = nil } })) {
            Button("好", role: .cancel) { updateCheckMessage = nil }
        } message: {
            Text(updateCheckMessage ?? "")
        }
    }

    // MARK: - 个人阅读看板

    private var profileHeroCard: some View {
        VStack(spacing: 0) {
            if let username = auth.username {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [NoveliaStyle.brandGreen, NoveliaStyle.brandGreen.opacity(0.68)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text(String(username.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 50, height: 50)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: username)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(NoveliaStyle.ink)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(NoveliaStyle.brandGreen)
                                .frame(width: 6, height: 6)
                            Text("已登录 Novelia 账号")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                        }
                    }

                    Spacer(minLength: 8)

                    Button("退出登录", role: .destructive) { isConfirmingLogout = true }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(NoveliaStyle.danger.opacity(0.10), in: Capsule())
                        .buttonStyle(.plain)
                        .foregroundStyle(NoveliaStyle.danger)
                        .confirmationDialog("退出登录？", isPresented: $isConfirmingLogout, titleVisibility: .visible) {
                            Button("退出登录", role: .destructive) { auth.logout() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("小说与论坛使用同一账号，会一起退出。")
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            } else {
                Button {
                    auth.errorMessage = nil
                    auth.isLoginPresented = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(NoveliaStyle.brandGreen.opacity(0.14))
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(NoveliaStyle.brandGreen)
                        }
                        .frame(width: 50, height: 50)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("登录 / 注册")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(NoveliaStyle.ink)
                            Text("同步云端收藏、阅读历史与社区互动")
                                .font(.system(size: 12))
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.muted.opacity(0.55))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.75)
                .padding(.horizontal, 16)

            NavigationLink {
                ReadingStatisticsView()
            } label: {
                HStack(spacing: 0) {
                    heroMetric(value: todayReadingText, label: "今日阅读")
                    heroMetricDivider
                    heroMetric(value: "\(streakDays) 天", label: "连续阅读")
                    heroMetricDivider
                    heroMetric(value: "\(libraryBookCount) 本", label: "书库藏书")
                }
                .padding(.vertical, 13)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("阅读概览：今日阅读 \(todayReadingText)，连续阅读 \(streakDays) 天，书库藏书 \(libraryBookCount) 本")
        }
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }

    private func heroMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(NoveliaStyle.fontCaption)
                .foregroundStyle(NoveliaStyle.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var heroMetricDivider: some View {
        Rectangle()
            .fill(NoveliaStyle.hairline)
            .frame(width: 0.75, height: 24)
    }

    // MARK: - 常用功能快捷入口

    private var quickHubGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
        return LazyVGrid(columns: columns, spacing: 12) {
            NavigationLink {
                ReadingStatisticsView()
            } label: {
                MeQuickTile(
                    title: "阅读统计",
                    subtitle: "累计 \(totalReadingText)",
                    systemImage: "chart.bar.xaxis",
                    tint: NoveliaStyle.brandGreen
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                WebDAVSyncView()
            } label: {
                MeQuickTile(
                    title: "WebDAV 同步",
                    subtitle: webDAVStatusText,
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: webDAVSync.isEnabled ? NoveliaStyle.brandGreen : NoveliaStyle.muted,
                    highlightsSubtitle: webDAVSync.isEnabled
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                EPUBToolboxView()
            } label: {
                MeQuickTile(
                    title: "EPUB 工具箱",
                    subtitle: "体检、修复与转换",
                    systemImage: "wrench.and.screwdriver",
                    tint: Color.orange
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ReadingAISettingsView(store: services.readingAI)
            } label: {
                MeQuickTile(
                    title: "AI 阅读辅助",
                    subtitle: aiStatusText,
                    systemImage: "sparkles",
                    tint: Color.indigo,
                    highlightsSubtitle: services.readingAI.configuration.isEnabled
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 阅读偏好

    private var readingSection: some View {
        MeCardSection(title: "阅读偏好") {
            NavigationLink {
                SpeechSettingsView()
            } label: {
                MeNavigationRow(
                    title: "朗读",
                    systemImage: "speaker.wave.2",
                    iconTint: NoveliaStyle.brandGreen
                )
            }
            .buttonStyle(.plain)

            MeRowDivider()

            NavigationLink {
                ReaderBackgroundSettingsView()
            } label: {
                MeNavigationRow(
                    title: "阅读背景",
                    systemImage: "paintbrush",
                    iconTint: Color.teal
                )
            }
            .buttonStyle(.plain)

            MeRowDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    MeIconBadge(systemImage: "textformat.size", tint: NoveliaStyle.brandGreen)
                    Text("正文字号")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    Spacer()
                    Text("\(Int(readerSettings.fontSize)) pt")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                }
                Slider(value: $readerSettings.fontSize, in: ReaderSettings.fontRange, step: 1)
                    .tint(NoveliaStyle.brandGreen)
                    .accessibilityLabel("正文字号")
                    .accessibilityValue("\(Int(readerSettings.fontSize)) 点")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            MeRowDivider()

            HStack(spacing: 12) {
                MeIconBadge(systemImage: "character.book.closed", tint: Color.blue)
                Text("显示语言")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink)
                Spacer()
                Menu {
                    Picker("显示语言", selection: $modeRaw) {
                        ForEach(ReaderMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedMode.title)
                            .font(.system(size: 14))
                            .foregroundStyle(NoveliaStyle.muted)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("显示语言：\(selectedMode.title)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            MeRowDivider()

            NavigationLink {
                MoreReadingSettingsView()
            } label: {
                MeNavigationRow(
                    title: "更多阅读与书库设置",
                    subtitle: "分章规则、自动状态、入库体检与分页引擎",
                    systemImage: "slider.horizontal.3",
                    iconTint: NoveliaStyle.muted
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 外观与界面

    private var appearanceSection: some View {
        MeCardSection(title: "外观与界面") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    MeIconBadge(systemImage: "paintpalette", tint: NoveliaStyle.brandGreen)
                    Text("主题色")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    Spacer()
                    Text((AppThemeColor(rawValue: themeColorRaw) ?? .novelia).title)
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AppThemeColor.allCases) { option in
                            let isSelected = themeColorRaw == option.rawValue
                            let swatch = option == .custom ? AppThemeColor.color(fromHex: themeCustomHex) : option.color
                            Button {
                                NoveliaHaptics.selection()
                                themeColorRaw = option.rawValue
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        Circle()
                                            .fill(swatch)
                                            .frame(width: 30, height: 30)
                                        if option == .custom && !isSelected {
                                            Image(systemName: "eyedropper")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .padding(3)
                                    .overlay(
                                        Circle()
                                            .stroke(isSelected ? swatch : Color.clear, lineWidth: 2)
                                    )
                                    Text(option.title)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? NoveliaStyle.ink : NoveliaStyle.muted)
                                }
                                .frame(minWidth: 46)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("主题色：\(option.title)")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
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
                    .font(.system(size: 14))
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            MeRowDivider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    MeIconBadge(systemImage: "square.on.square", tint: Color.brown)
                    Text("界面底色")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    Spacer()
                    Text(AppPaperStyle.from(storedValue: paperStyleRaw).title)
                        .font(.system(size: 13))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                HStack(spacing: 10) {
                    ForEach(AppPaperStyle.allCases) { option in
                        let isSelected = paperStyleRaw == option.rawValue
                        Button {
                            NoveliaHaptics.selection()
                            paperStyleRaw = option.rawValue
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                                    .fill(option.swatchColor)
                                    .frame(height: 36)
                                    .overlay(alignment: .bottomTrailing) {
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(NoveliaStyle.brandGreen)
                                                .padding(4)
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                                            .stroke(isSelected ? NoveliaStyle.brandGreen : NoveliaStyle.hairline, lineWidth: isSelected ? 2 : 1)
                                    )
                                Text(option.shortTitle)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? NoveliaStyle.ink : NoveliaStyle.muted)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("界面底色：\(option.title)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            MeRowDivider()

            HStack(spacing: 12) {
                MeIconBadge(systemImage: "moon.fill", tint: Color.indigo)
                Toggle(isOn: $appDarkOLED) {
                    Text("深色使用纯黑（OLED）")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                }
                .tint(NoveliaStyle.brandGreen)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            MeRowDivider()

            NavigationLink {
                TabBarSettingsView()
            } label: {
                MeNavigationRow(
                    title: "自定义底栏",
                    systemImage: "dock.rectangle",
                    iconTint: Color.purple
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 数据与连接

    private var dataAndNetworkSection: some View {
        MeCardSection(title: "数据与连接") {
            NavigationLink {
                NetworkECHSettingsView()
            } label: {
                MeNavigationRow(
                    title: "加密连接（ECH）",
                    value: echEnabled ? "已开启" : "已关闭",
                    valueHighlighted: echEnabled,
                    systemImage: "lock.shield",
                    iconTint: NoveliaStyle.brandGreen
                )
            }
            .buttonStyle(.plain)

            MeRowDivider()

            NavigationLink {
                OfflineChapterManagementView()
            } label: {
                MeNavigationRow(
                    title: "离线章节管理",
                    systemImage: "internaldrive",
                    iconTint: Color.blue
                )
            }
            .buttonStyle(.plain)

            MeRowDivider()

            NavigationLink {
                BlockedTagsView()
            } label: {
                MeNavigationRow(
                    title: "标签屏蔽",
                    systemImage: "tag.slash",
                    iconTint: Color.orange
                )
            }
            .buttonStyle(.plain)

            MeRowDivider()

            NavigationLink {
                LocalBackupView()
            } label: {
                MeNavigationRow(
                    title: "本地备份与恢复",
                    systemImage: "archivebox",
                    iconTint: Color.teal
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 关于与高级

    private var aboutSection: some View {
        MeCardSection(title: "关于与高级") {
            if services.performsUpdateChecks {
                Button {
                    Task { await checkForUpdates() }
                } label: {
                    MeNavigationRow(
                        title: updates.isCheckingManually ? "正在检查更新…" : "检查更新",
                        value: "v\(appVersion)",
                        systemImage: updates.isCheckingManually ? "hourglass" : "arrow.down.circle",
                        iconTint: NoveliaStyle.brandGreen,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(updates.isCheckingManually)

                MeRowDivider()
            }

            NavigationLink {
                AboutAndDiagnosticsView()
            } label: {
                MeNavigationRow(
                    title: "关于、许可与诊断",
                    subtitle: "开源许可、更新偏好与日志导出",
                    systemImage: "info.circle",
                    iconTint: NoveliaStyle.muted
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var footerView: some View {
        HStack {
            Spacer()
            #if NOVELIA_READIUM_ONLY
            Text("Novelia · v\(appVersion) · iOS 15+")
            #else
            Text("Novelia · v\(appVersion)")
            #endif
            Spacer()
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(NoveliaStyle.muted.opacity(0.65))
        .padding(.top, 4)
    }

    /// 有新版本时由根视图弹出“发现新版本”；这里只提示已是最新或检查失败。
    private func checkForUpdates() async {
        switch await updates.checkManually() {
        case .available: break
        case .upToDate(let current): updateCheckMessage = "暂无更新的公开正式版（当前 \(current)）。"
        case .inProgress: break
        case .failed: updateCheckMessage = "暂时无法获取 GitHub 版本信息，请稍后重试。"
        case .rateLimited: updateCheckMessage = "GitHub 暂时限制了当前网络的更新查询，备用页面也未能连接。请稍后重试或切换网络。"
        }
    }
}

// MARK: - 「我的」页轻量组件与二级设置页

private struct MeCardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoveliaStyle.muted)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                content
            }
            .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        }
    }
}

private struct MeIconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct MeRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(NoveliaStyle.hairline)
            .frame(height: 0.75)
            .padding(.leading, 54)
    }
}

private struct MeNavigationRow: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueHighlighted: Bool = false
    let systemImage: String
    let iconTint: Color
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            MeIconBadge(systemImage: systemImage, tint: iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoveliaStyle.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: valueHighlighted ? .semibold : .regular))
                    .foregroundStyle(valueHighlighted ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct MeQuickTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var highlightsSubtitle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MeIconBadge(systemImage: systemImage, tint: tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted.opacity(0.45))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NoveliaStyle.fontFootnote)
                    .foregroundStyle(highlightsSubtitle ? tint : NoveliaStyle.muted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        .contentShape(RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
    }
}

private struct MeToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let iconTint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            MeIconBadge(systemImage: systemImage, tint: iconTint)
                .padding(.top, subtitle == nil ? 0 : 1)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(NoveliaStyle.fontCaption)
                            .foregroundStyle(NoveliaStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(NoveliaStyle.brandGreen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MeSectionFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NoveliaStyle.fontCaption)
            .foregroundStyle(NoveliaStyle.muted)
            .padding(.horizontal, 8)
            .padding(.top, -8)
    }
}

/// 收敛低频阅读与书库行为开关，保持「我的」首屏简洁，并沿用统一纸面卡片风格。
private struct MoreReadingSettingsView: View {
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

/// 收敛关于信息、更新开关、开源许可与诊断日志，采用统一纸面卡片风格。
private struct AboutAndDiagnosticsView: View {
    @AppStorage(NoveliaUpdateStore.enabledKey) private var checksUpdates = true
    @AppStorage(ReaderDebugOptions.showsTOCDiagnosticsKey) private var showsTOCDiagnostics = false
    #if !NOVELIA_READIUM_ONLY
    @AppStorage(SettingsKey.readerEPUBReadium) private var epubUsesReadium = false
    #endif
    @EnvironmentObject private var updates: NoveliaUpdateStore
    @EnvironmentObject private var services: AppServices
    @State private var updateCheckMessage: String?
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

                    if services.performsUpdateChecks {
                        MeRowDivider()

                        Button {
                            Task { await checkForUpdates() }
                        } label: {
                            MeNavigationRow(
                                title: updates.isCheckingManually ? "正在检查更新…" : "检查更新",
                                value: "v\(appVersion)",
                                systemImage: updates.isCheckingManually ? "hourglass" : "arrow.down.circle",
                                iconTint: Color.blue,
                                showsChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(updates.isCheckingManually)
                    }

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
        .alert("检查更新", isPresented: .init(get: { updateCheckMessage != nil }, set: { if !$0 { updateCheckMessage = nil } })) {
            Button("好", role: .cancel) { updateCheckMessage = nil }
        } message: {
            Text(updateCheckMessage ?? "")
        }
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

    private func checkForUpdates() async {
        switch await updates.checkManually() {
        case .available: break
        case .upToDate(let current): updateCheckMessage = "暂无更新的公开正式版（当前 \(current)）。"
        case .inProgress: break
        case .failed: updateCheckMessage = "暂时无法获取 GitHub 版本信息，请稍后重试。"
        case .rateLimited: updateCheckMessage = "GitHub 暂时限制了当前网络的更新查询，备用页面也未能连接。请稍后重试或切换网络。"
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

/// 调整底栏页面顺序，并选择每次打开 App 时显示的页面。
/// 顺序先在本页编辑，离开本页时才写入：底栏会因顺序改变而重建，编辑中写入会把本页一并关闭。
private struct TabBarSettingsView: View {
    @AppStorage(SettingsKey.tabBarOrder) private var orderRaw = ""
    @AppStorage(SettingsKey.tabBarLaunch) private var launchRaw = AppLaunchTab.default.rawValue
    @State private var order: [AppTab] = AppTabLayout.order(from: UserDefaults.standard.string(forKey: SettingsKey.tabBarOrder))

    var body: some View {
        List {
            Section {
                ForEach(order) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .onMove { source, destination in
                    order.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text("底栏顺序")
            } footer: {
                Text("按住右侧把手拖动调整顺序，从上到下对应底栏从左到右；返回上一页后生效。")
            }
            Section {
                Picker("启动时打开", selection: $launchRaw) {
                    ForEach(order) { tab in
                        Text(tab.title).tag(AppLaunchTab.fixed(tab).rawValue)
                    }
                    Text("上次使用的页面").tag(AppLaunchTab.lastUsedRawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("启动时打开")
            } footer: {
                Text("下次打开 App 时生效。")
            }
            Section {
                Button("恢复默认") {
                    order = AppTabLayout.defaultOrder
                    launchRaw = AppLaunchTab.default.rawValue
                }
                .disabled(order == AppTabLayout.defaultOrder && AppLaunchTab(rawValue: launchRaw) == .default)
            }
        }
        .environment(\.editMode, .constant(.active))
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("自定义底栏")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            let stored = AppTabLayout.storedValue(for: order)
            if stored != AppTabLayout.storedValue(for: AppTabLayout.order(from: orderRaw)) { orderRaw = stored }
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
    static let modifiedDate = "2026-11-25"
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

/// 界面底色选择器里的纸面色卡；独立视图避免 Form 主体表达式类型检查超时。
private struct PaperStyleSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(NoveliaStyle.muted.opacity(0.35), lineWidth: 1))
            .frame(width: 12, height: 12)
    }
}

/// Novelia 原站 ECH（加密 SNI）开关、自定义 DoH 节点与连接诊断页。
private struct NetworkECHSettingsView: View {
    @AppStorage(SettingsKey.networkECHEnabled) private var echEnabled = false
    @State private var customDoHDraft: String = NoveliaECHController.shared.customDoHRaw
    @State private var dohFeedback: String?
    @State private var dohFeedbackIsError = false
    @State private var isProbing = false
    @State private var probeReports: [ECHProbeReport] = []
    @State private var recentRecords: [ECHRequestDiagnosticRecord] = NoveliaECHController.shared.recentDiagnostics
    @State private var resetNotice: String?

    private static let dohPresets: [(title: String, value: String)] = [
        ("内置默认", ""),
        ("阿里 DNS", "https://dns.alidns.com/dns-query\nhttps://223.5.5.5/dns-query"),
        ("Cloudflare", "https://1.1.1.1/dns-query\nhttps://cloudflare-dns.com/dns-query"),
        ("Google", "https://8.8.8.8/dns-query")
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $echEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 ECH（加密 SNI）")
                        Text("使用内置 DoH 与 TLS 1.3 ECH 连接 Novelia 原站。握手失败时不静默降级为明文 SNI。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("仅对 n.novelia.cc、auth.novelia.cc 与 forum.novelia.cc（HTTPS 443）生效；WebDAV、外部图床、更新检查与 AI 服务不受影响。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每行填写一个 https:// DoH 地址（最多 8 个），留空则使用内置默认节点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $customDoHDraft)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 76)
                        .padding(6)
                        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.dohPresets, id: \.title) { preset in
                                Button(preset.title) {
                                    customDoHDraft = preset.value
                                    applyDoH(preset.value)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Button("保存并应用 DoH 节点") {
                    applyDoH(customDoHDraft)
                }

                if let dohFeedback {
                    Text(dohFeedback)
                        .font(.caption)
                        .foregroundStyle(dohFeedbackIsError ? NoveliaStyle.danger : NoveliaStyle.brandGreen)
                }
            } header: {
                Text("DoH 解析节点")
            } footer: {
                Text("内置默认节点：\(NoveliaECHController.defaultDoHDescription)。")
            }

            Section {
                Button {
                    runDiagnostics()
                } label: {
                    HStack(spacing: 8) {
                        if isProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(isProbing ? "正在诊断…" : "运行 ECH 连接诊断")
                    }
                }
                .disabled(isProbing)

                ForEach(probeReports) { report in
                    DisclosureGroup {
                        ECHEventTimelineView(events: report.events)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: report.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.ok ? NoveliaStyle.brandGreen : NoveliaStyle.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(report.host)
                                        .font(.subheadline.monospaced())
                                    Spacer()
                                    if report.elapsedMs > 0 {
                                        Text("\(report.elapsedMs) ms")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(report.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button("重置连接池与 DNS 缓存") {
                    NoveliaECHController.shared.resetNetworkState()
                    resetNotice = "已重置 ECH 连接池与解析缓存。"
                }
                .disabled(isProbing)
            } header: {
                Text("连接诊断")
            } footer: {
                if let resetNotice {
                    Text(resetNotice)
                } else {
                    Text("诊断仅发起匿名 TLS 1.3 / ECH 握手测试，展开各域名可查看 DoH、代理、TCP 与 TLS 阶段耗时；脱敏诊断同时写入“导出应用日志”。")
                }
            }

            Section {
                if recentRecords.isEmpty {
                    Text("暂无 ECH 请求记录。开启 ECH 并发起浏览或登录后，可在此查看最近 30 条请求的阶段明细。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentRecords) { record in
                        DisclosureGroup {
                            ECHEventTimelineView(events: record.events)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: record.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(record.outcome == "ok" ? NoveliaStyle.brandGreen : NoveliaStyle.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(record.method) \(record.host)")
                                            .font(.caption.monospaced())
                                        Spacer()
                                        Text("\(record.elapsedMs) ms")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(recordSummary(record))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("刷新明细") {
                        recentRecords = NoveliaECHController.shared.recentDiagnostics
                    }
                    Spacer()
                    if !recentRecords.isEmpty {
                        Button("清空", role: .destructive) {
                            NoveliaECHController.shared.clearRecentDiagnostics()
                            recentRecords = []
                        }
                    }
                }
            } header: {
                Text("最近 ECH 请求明细")
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("加密连接（ECH）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customDoHDraft = NoveliaECHController.shared.customDoHRaw
            recentRecords = NoveliaECHController.shared.recentDiagnostics
        }
    }

    private func applyDoH(_ value: String) {
        if let error = NoveliaECHController.shared.applyCustomDoH(value) {
            dohFeedback = error
            dohFeedbackIsError = true
        } else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            customDoHDraft = trimmed
            dohFeedback = trimmed.isEmpty ? "已恢复使用内置默认 DoH 节点。" : "已保存自定义 DoH 节点并重置解析缓存。"
            dohFeedbackIsError = false
        }
    }

    private func runDiagnostics() {
        guard !isProbing else { return }
        isProbing = true
        resetNotice = nil
        probeReports = NoveliaECHController.protectedHosts.map {
            ECHProbeReport(host: $0, ok: false, summary: "检测中…", elapsedMs: 0, events: [])
        }
        Task {
            var collected: [ECHProbeReport] = []
            for host in NoveliaECHController.protectedHosts {
                let report = await NoveliaECHController.shared.probeDiagnostics(host: host)
                collected.append(report)
                let pending = NoveliaECHController.protectedHosts.dropFirst(collected.count).map {
                    ECHProbeReport(host: $0, ok: false, summary: "等待中…", elapsedMs: 0, events: [])
                }
                probeReports = collected + pending
            }
            probeReports = collected
            recentRecords = NoveliaECHController.shared.recentDiagnostics
            isProbing = false
        }
    }

    private func recordSummary(_ record: ECHRequestDiagnosticRecord) -> String {
        let time = Self.timeFormatter.string(from: record.timestamp)
        if let status = record.statusCode {
            return "\(time) · HTTP \(status)"
        }
        if let label = record.failureLabel {
            return "\(time) · \(label)"
        }
        return "\(time) · \(record.outcome)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct ECHEventTimelineView: View {
    let events: [ECHDiagnosticEvent]

    var body: some View {
        if events.isEmpty {
            Text("暂无阶段事件")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("+\(event.atMillis)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.stageDisplayName) · \(event.outcome)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(event.outcome == "failed" ? NoveliaStyle.danger : NoveliaStyle.ink)
                            let detail = eventDetail(event)
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func eventDetail(_ event: ECHDiagnosticEvent) -> String {
        var parts: [String] = []
        if let duration = event.durationMs, duration > 0 { parts.append("\(duration)ms") }
        if let resolver = event.resolver, !resolver.isEmpty { parts.append("doh=\(resolver)") }
        if let family = event.family, !family.isEmpty { parts.append(family) }
        if let ip = event.serverIp, !ip.isEmpty { parts.append("ip=\(ip)") }
        if let proto = event.protocolName, !proto.isEmpty { parts.append(proto) }
        if let reason = event.reason, !reason.isEmpty { parts.append("reason=\(reason)") }
        return parts.joined(separator: " · ")
    }
}
