import SwiftUI

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
