import SwiftUI
import Charts

private enum ReadingDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分钟" }
        return "\(value / 3600) 小时 \((value % 3600) / 60) 分钟"
    }

    static func weekSeconds(_ statistics: ReadingStatistics, at date: Date, calendar: Calendar = .current) -> TimeInterval {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
            .map { ReadingStatistics.dayKey($0, calendar: calendar) })
        return statistics.seconds(days: days)
    }
}

struct ReadingStatisticsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @EnvironmentObject private var store: ReadingStatisticsStore
    @EnvironmentObject private var libraryState: LibraryStateStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore
    @EnvironmentObject private var cloudBooks: CloudBookStore

    @State private var showsSyncOffer = false
    @State private var range = 7
    @State private var selectedDay: String?
    @State private var sortByTime = true
    @State private var showAllBooks = false
    @State private var showAllCompleted = false
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var pendingRemoveDevice: ReadingDeviceStatistics?

    private var calendar: Calendar { Calendar.current }

    private var sortedBooks: [ReadingBookStatistics] {
        store.statistics.books.values.sorted {
            if sortByTime, $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.lastReadAt != $1.lastReadAt { return $0.lastReadAt > $1.lastReadAt }
            return $0.id < $1.id
        }
    }

    private var allLibraryBooks: [LibraryBook] {
        libraryState.books(web: webDownloads, wenku: wenkuDownloads, cloud: cloudBooks)
    }

    private var libraryBooksByKey: [String: LibraryBook] {
        Dictionary(allLibraryBooks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var completedRecords: [AnnualCompletedBook] {
        let booksByKey = libraryBooksByKey
        return libraryState.readingStatuses.statuses.compactMap { key, entry -> AnnualCompletedBook? in
            guard entry.status == .completed else { return nil }
            let libraryBook = booksByKey[key]
            let statEntry = store.statistics.books[key]
            let title = libraryBook?.title ?? statEntry?.book.title
            guard let title, !title.isEmpty else { return nil }
            let year = calendar.component(.year, from: entry.updatedAt)
            return AnnualCompletedBook(
                id: key,
                title: title,
                author: libraryBook?.author ?? "",
                completedAt: entry.updatedAt,
                year: year,
                recordedSeconds: statEntry?.seconds ?? 0,
                libraryBook: libraryBook
            )
        }
        .sorted { $0.completedAt > $1.completedAt }
    }

    private var readingCount: Int {
        let unique = libraryState.displayBooks(from: allLibraryBooks)
        return unique.filter { libraryState.bookStatus(for: $0) == .reading }.count
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = ReadingStatistics.dayKey(context.date, calendar: calendar)
            let dates = (0..<range).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: context.date) }
            let isWide = horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    recordingHeaderCard
                    ReadingOverviewMetrics(
                        today: ReadingDuration.text(store.statistics.seconds(days: [today])),
                        week: ReadingDuration.text(ReadingDuration.weekSeconds(store.statistics, at: context.date)),
                        total: ReadingDuration.text(store.statistics.seconds()),
                        streak: store.statistics.streakDays(asOf: context.date, calendar: calendar),
                        days: store.statistics.readingDays,
                        isWide: isWide,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                    )
                    ReadingHeatmapCard(
                        statistics: store.statistics,
                        today: today,
                        now: context.date,
                        calendar: calendar,
                        selectedDay: $selectedDay
                    )
                    AnnualCompletedCard(
                        records: completedRecords,
                        readingCount: readingCount,
                        currentYear: calendar.component(.year, from: context.date),
                        selectedYear: $selectedYear,
                        showAll: $showAllCompleted
                    )
                    dailyTrendCard(dates: dates, today: today)
                    ReadingKindDistributionCard(statistics: store.statistics)
                    booksCard
                    devicesCard(today: today)
                    footnoteCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
            .background(NoveliaStyle.paper.ignoresSafeArea())
        }
        .confirmationDialog("开启阅读时长同步？", isPresented: $showsSyncOffer, titleVisibility: .visible) {
            Button("开启同步") { syncStore.syncStatistics = true }
            Button("暂不开启", role: .cancel) {}
        } message: {
            Text("你已开启 WebDAV 同步。是否同时开启阅读时长同步？之后各设备的阅读统计会随 WebDAV 同步合并。")
        }
        .alert("移除设备“\(pendingRemoveDevice?.name ?? "")”的统计？",
               isPresented: .init(get: { pendingRemoveDevice != nil }, set: { if !$0 { pendingRemoveDevice = nil } }),
               presenting: pendingRemoveDevice) { device in
            Button("移除", role: .destructive) {
                store.removeDevice(id: device.id)
                pendingRemoveDevice = nil
            }
            Button("取消", role: .cancel) { pendingRemoveDevice = nil }
        } message: { _ in
            Text("将从本机移除该设备的阅读统计记录。若开启了 WebDAV 统计同步且云端仍保留该设备文件，下次同步可能会重新拉回。")
        }
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var recordingHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.isRecordingEnabled ? NoveliaStyle.brandGreen : NoveliaStyle.muted.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text("READING INSIGHTS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .compatTracking(1.2)
                            .foregroundStyle(store.isRecordingEnabled ? NoveliaStyle.brandGreen : NoveliaStyle.muted)
                    }
                    Text("记录阅读时长")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { store.isRecordingEnabled },
                    set: { enabled in
                        showsSyncOffer = store.setRecordingEnabled(enabled, webDAVEnabled: syncStore.isEnabled,
                                                                    statisticsSyncEnabled: syncStore.syncStatistics)
                    }))
                    .labelsHidden()
                    .tint(NoveliaStyle.brandGreen)
                    .accessibilityLabel("记录阅读时长")
            }
            Text("开启后记录 EPUB、TXT 和在线阅读时长；关闭后暂停新增记录，已有统计保留。WebDAV 同步开关位于“我的 → WebDAV 同步”。")
                .font(.caption)
                .foregroundStyle(NoveliaStyle.muted)
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private func dailyTrendCard(dates: [Date], today: String) -> some View {
        let activeDay = selectedDay ?? today
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatisticsCardHeader(title: "每日趋势", systemImage: "chart.bar.fill", tint: .blue)
                Spacer()
                Picker("时间范围", selection: $range) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)
            }
            ReadingDailyTrendChart(dates: dates, calendar: calendar, statistics: store.statistics, selectedDay: $selectedDay)
            Divider()
            NavigationLink {
                ReadingDayStatisticsView(day: activeDay)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeDay == today ? "今日（\(activeDay)）" : activeDay)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(NoveliaStyle.ink)
                        Text("点击查看当日三类阅读明细")
                            .font(.caption)
                            .foregroundStyle(NoveliaStyle.muted)
                    }
                    Spacer()
                    Text(ReadingDuration.text(store.statistics.seconds(days: [activeDay])))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private var booksCard: some View {
        let all = sortedBooks
        let visible = showAllBooks ? all : Array(all.prefix(10))
        let maxSeconds = max(all.map(\.seconds).max() ?? 0, 1)
        let booksByKey = libraryBooksByKey
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatisticsCardHeader(title: "书籍排行", systemImage: "books.vertical.fill", tint: NoveliaStyle.brandGreen)
                Spacer()
                Picker("排列方式", selection: $sortByTime) {
                    Text("时长").tag(true)
                    Text("最近").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 124)
            }
            if all.isEmpty {
                Text("还没有阅读记录。打开一本书开始阅读后，这里会显示单书耗时排行。")
                    .font(.subheadline)
                    .foregroundStyle(NoveliaStyle.muted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        let libraryBook = booksByKey[entry.id]
                        let author = libraryBook?.author ?? ""
                        NavigationLink {
                            ReadingBookStatisticsView(bookID: entry.id)
                        } label: {
                            HStack(alignment: .center, spacing: 11) {
                                StatisticsMiniCover(book: libraryBook, rank: sortByTime ? index + 1 : nil)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(entry.book.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(NoveliaStyle.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(ReadingDuration.text(entry.seconds))
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(NoveliaStyle.brandGreen)
                                    }
                                    if !author.isEmpty {
                                        Text(author)
                                            .font(.caption)
                                            .foregroundStyle(NoveliaStyle.muted)
                                            .lineLimit(1)
                                    }
                                    GeometryReader { geo in
                                        let ratio = min(1, max(0.03, entry.seconds / maxSeconds))
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(NoveliaStyle.paper)
                                            Capsule().fill(readingKindColor(entry.book.kind).opacity(0.75))
                                                .frame(width: geo.size.width * ratio)
                                        }
                                    }
                                    .frame(height: 5)
                                    HStack {
                                        Text(entry.book.kind.title)
                                        Text("·")
                                        Text("最后阅读 \(entry.lastReadAt.formatted(date: .abbreviated, time: .shortened))")
                                        Spacer()
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(NoveliaStyle.muted)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if index < visible.count - 1 {
                            Divider()
                        }
                    }
                }
                if all.count > 10 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAllBooks.toggle() }
                    } label: {
                        Text(showAllBooks ? "收起列表" : "展开全部 \(all.count) 本书")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private func devicesCard(today: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatisticsCardHeader(title: "同步设备", systemImage: "laptopcomputer.and.iphone", tint: .purple)
            VStack(spacing: 10) {
                ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 10) {
                        NavigationLink {
                            ReadingDeviceStatisticsView(deviceID: device.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.model == "iPad" ? "ipad" : "iphone")
                                    .font(.system(size: 16))
                                    .foregroundStyle(NoveliaStyle.brandGreen)
                                    .frame(width: 28, height: 28)
                                    .background(NoveliaStyle.brandGreen.opacity(0.1), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(device.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(NoveliaStyle.ink)
                                            .lineLimit(1)
                                        if device.isCurrent {
                                            Text("本机")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(NoveliaStyle.brandGreen)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(NoveliaStyle.brandGreen.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text("今日 \(ReadingDuration.text(device.statistics.seconds(days: [today]))) · 累计 \(ReadingDuration.text(device.statistics.seconds()))")
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(NoveliaStyle.muted.opacity(0.55))
                            }
                        }
                        .buttonStyle(.plain)
                        if !device.isCurrent {
                            Button {
                                pendingRemoveDevice = device
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(NoveliaStyle.danger)
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除设备 \(device.name)")
                        }
                    }
                    if index < store.devices.count - 1 {
                        Divider()
                    }
                }
            }
            Text(store.devices.count > 1
                 ? "上方概览为所有设备合计。其他设备的时长在 WebDAV 同步后更新。"
                 : "开启 WebDAV 阅读时长同步后，这里会显示其他设备的阅读时长。")
                .font(.caption)
                .foregroundStyle(NoveliaStyle.muted)
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private var footnoteCard: some View {
        Text("正文加载成功且阅读器处于前台时计时；锁屏、后台或退出后暂停。当天累计满 1 分钟计为一个阅读日并点亮热力图。删除书籍保留历史统计；多设备统计随 WebDAV 同步合并。")
            .font(.footnote)
            .foregroundStyle(NoveliaStyle.muted)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
    }
}

private struct StatisticsCardHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NoveliaStyle.ink)
        }
    }
}

/// 核心概览卡片网格：常规为 2×2，宽屏为 4 列，无障碍超大字号退化为单列。
private struct ReadingOverviewMetrics: View {
    let today: String
    let week: String
    let total: String
    let streak: Int
    let days: Int
    let isWide: Bool
    let isAccessibilitySize: Bool

    private var columns: [GridItem] {
        if isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        let count = isWide ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            cell("今日阅读", value: today, subtitle: nil, icon: "sun.max.fill", tint: NoveliaStyle.brandGreen)
            cell("本周阅读", value: week, subtitle: nil, icon: "calendar", tint: .blue)
            cell("累计时长", value: total, subtitle: nil, icon: "clock.fill", tint: .purple)
            cell("连续阅读", value: "\(streak) 天", subtitle: "累计 \(days) 天", icon: "flame.fill", tint: .orange)
        }
    }

    private func cell(_ title: String, value: String, subtitle: String?, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(tint.opacity(0.12), in: Circle())
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NoveliaStyle.muted)
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(NoveliaStyle.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle.map { "\(value)，\($0)" } ?? value)
    }
}

/// GitHub 风格近 18 周每日阅读热力图，点按任意日期格可联动查看当日明细。
private struct ReadingHeatmapCard: View {
    let statistics: ReadingStatistics
    let today: String
    let now: Date
    let calendar: Calendar
    @Binding var selectedDay: String?

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月"
        return f
    }()

    var body: some View {
        let columns = statistics.heatmapColumns(weeks: 18, endingAt: now, calendar: calendar)
        let activeDay = selectedDay ?? today
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatisticsCardHeader(title: "阅读热力图", systemImage: "square.grid.3x3.fill", tint: NoveliaStyle.brandGreen)
                Spacer()
                HStack(spacing: 4) {
                    Text("少").font(.caption2).foregroundStyle(NoveliaStyle.muted)
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(cellColor(level: level, isFuture: false))
                            .frame(width: 10, height: 10)
                    }
                    Text("多").font(.caption2).foregroundStyle(NoveliaStyle.muted)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    // 月份标记行
                    HStack(spacing: 4) {
                        Color.clear.frame(width: 16, height: 12)
                        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                            Text(monthLabel(for: index, in: columns))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(NoveliaStyle.muted)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: 13, alignment: .leading)
                        }
                    }
                    HStack(alignment: .top, spacing: 4) {
                        VStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { row in
                                Text(weekdayLabel(row))
                                    .font(.system(size: 9))
                                    .foregroundStyle(NoveliaStyle.muted)
                                    .frame(width: 16, height: 13)
                            }
                        }
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 4) {
                                ForEach(column) { cell in
                                    let isSelected = activeDay == cell.dayKey
                                    Button {
                                        guard !cell.isFuture else { return }
                                        selectedDay = cell.dayKey
                                    } label: {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(cellColor(level: cell.level, isFuture: cell.isFuture))
                                            .frame(width: 13, height: 13)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .stroke(isSelected ? NoveliaStyle.ink : Color.clear, lineWidth: 1.4)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(cell.isFuture)
                                    .accessibilityLabel("\(cell.dayKey)，\(ReadingDuration.text(cell.seconds))")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()
            NavigationLink {
                ReadingDayStatisticsView(day: activeDay)
            } label: {
                HStack {
                    Text(activeDay == today ? "今日 \(activeDay)" : activeDay)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(NoveliaStyle.ink)
                    Spacer()
                    Text(ReadingDuration.text(statistics.seconds(days: [activeDay])))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NoveliaStyle.brandGreen)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private func cellColor(level: Int, isFuture: Bool) -> Color {
        if isFuture { return Color.clear }
        switch level {
        case 0: return NoveliaStyle.paper
        case 1: return NoveliaStyle.brandGreen.opacity(0.25)
        case 2: return NoveliaStyle.brandGreen.opacity(0.5)
        case 3: return NoveliaStyle.brandGreen.opacity(0.76)
        default: return NoveliaStyle.brandGreen
        }
    }

    private func monthLabel(for index: Int, in columns: [[ReadingHeatmapCell]]) -> String {
        guard let first = columns[index].first?.date else { return "" }
        let month = calendar.component(.month, from: first)
        if index == 0 { return Self.monthFormatter.string(from: first) }
        guard let prev = columns[index - 1].first?.date else { return "" }
        return calendar.component(.month, from: prev) == month ? "" : Self.monthFormatter.string(from: first)
    }

    private func weekdayLabel(_ row: Int) -> String {
        // 仅标注隔行星期，避免纵轴拥挤
        switch row {
        case 1: return "一"
        case 3: return "三"
        case 5: return "五"
        default: return ""
        }
    }
}

private struct AnnualCompletedBook: Identifiable {
    let id: String
    let title: String
    let author: String
    let completedAt: Date
    let year: Int
    let recordedSeconds: TimeInterval
    let libraryBook: LibraryBook?
}

/// 统计列表中的迷你封面：在书库中时直接复用 `LibraryCoverView`，已删除的历史书退化为柔和占位卡。
private struct StatisticsMiniCover: View {
    let book: LibraryBook?
    var rank: Int? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let book {
                LibraryCoverView(book: book, width: 36, height: 50)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(NoveliaStyle.paper)
                    .frame(width: 36, height: 50)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.system(size: 13))
                            .foregroundStyle(NoveliaStyle.muted.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
                    )
            }
            if let rank {
                Text("\(rank)")
                    .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(rank <= 3 ? Color.white : NoveliaStyle.ink)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(rank <= 3 ? NoveliaStyle.brandGreen.opacity(1.0 - Double(rank - 1) * 0.18) : NoveliaStyle.card)
                    )
                    .overlay(Circle().stroke(NoveliaStyle.card, lineWidth: 1))
                    .offset(x: -5, y: -5)
            }
        }
    }
}

/// 年度完读统计卡片：按书库“读过”状态与标记年份汇总本年完读书单。
private struct AnnualCompletedCard: View {
    let records: [AnnualCompletedBook]
    let readingCount: Int
    let currentYear: Int
    @Binding var selectedYear: Int
    @Binding var showAll: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    private var availableYears: [Int] {
        var years = Set(records.map(\.year))
        years.insert(currentYear)
        return years.sorted(by: >)
    }

    var body: some View {
        let yearBooks = records.filter { $0.year == selectedYear }
        let visible = showAll ? yearBooks : Array(yearBooks.prefix(5))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatisticsCardHeader(title: "年度完读统计", systemImage: "checkmark.seal.fill", tint: NoveliaStyle.brandGreen)
                Spacer()
                if availableYears.count > 1 {
                    Menu {
                        ForEach(availableYears, id: \.self) { year in
                            let yearText = "\(String(year)) 年"
                            Button {
                                selectedYear = year
                            } label: {
                                if year == selectedYear {
                                    Label(yearText, systemImage: "checkmark")
                                } else {
                                    Text(yearText)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(String(selectedYear)) 年")
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.brandGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(NoveliaStyle.brandGreen.opacity(0.1), in: Capsule())
                    }
                } else {
                    Text("\(String(selectedYear)) 年")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NoveliaStyle.muted)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(yearBooks.count)")
                        .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(NoveliaStyle.ink)
                    Text("本完读")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NoveliaStyle.muted)
                }
                Spacer()
                HStack(spacing: 8) {
                    statPill("累计读过 \(records.count)")
                    statPill("在读 \(readingCount)")
                }
            }

            if yearBooks.isEmpty {
                Text("在书库书籍菜单中将读完的书标记为“读过”，这里会自动汇总 \(String(selectedYear)) 年完读书单。")
                    .font(.caption)
                    .foregroundStyle(NoveliaStyle.muted)
                    .padding(.vertical, 2)
            } else {
                Divider()
                VStack(spacing: 10) {
                    ForEach(visible) { item in
                        HStack(alignment: .center, spacing: 11) {
                            StatisticsMiniCover(book: item.libraryBook)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .lineLimit(1)
                                if !item.author.isEmpty {
                                    Text(item.author)
                                        .font(.caption)
                                        .foregroundStyle(NoveliaStyle.muted)
                                        .lineLimit(1)
                                }
                                HStack(spacing: 6) {
                                    Text("完读于 \(Self.dateFormatter.string(from: item.completedAt))")
                                    if item.recordedSeconds >= 60 {
                                        Text("·")
                                        Text(ReadingDuration.text(item.recordedSeconds))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(NoveliaStyle.muted)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(NoveliaStyle.brandGreen)
                        }
                    }
                }
                if yearBooks.count > 5 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                    } label: {
                        Text(showAll ? "收起书单" : "查看全部 \(yearBooks.count) 本完读")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }

    private func statPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(NoveliaStyle.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NoveliaStyle.paper, in: Capsule())
    }
}

/// 累计阅读类型分布卡片：顶部统一堆叠比例条 + 三类明细。
private struct ReadingKindDistributionCard: View {
    let statistics: ReadingStatistics

    var body: some View {
        let total = statistics.seconds()
        VStack(alignment: .leading, spacing: 12) {
            StatisticsCardHeader(title: "阅读类型分布", systemImage: "chart.pie.fill", tint: .orange)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if total <= 0 {
                        Capsule().fill(NoveliaStyle.paper)
                    } else {
                        ForEach(ReadingKind.allCases) { kind in
                            let seconds = statistics.seconds(kind: kind)
                            if seconds > 0 {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(readingKindColor(kind))
                                    .frame(width: max(4, (geo.size.width - 4) * (seconds / total)))
                            }
                        }
                    }
                }
            }
            .frame(height: 10)

            VStack(spacing: 8) {
                ForEach(ReadingKind.allCases) { kind in
                    let seconds = statistics.seconds(kind: kind)
                    let percent = total > 0 ? seconds / total * 100 : 0
                    HStack(spacing: 8) {
                        Circle().fill(readingKindColor(kind)).frame(width: 8, height: 8)
                        Text(kind.title)
                            .font(.subheadline)
                            .foregroundStyle(NoveliaStyle.ink)
                        Spacer()
                        Text(ReadingDuration.text(seconds))
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(NoveliaStyle.ink)
                        Text(String(format: "%.1f%%", percent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NoveliaStyle.muted)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(NoveliaStyle.card, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusLarge, style: .continuous)
                .stroke(NoveliaStyle.hairline, lineWidth: 0.75)
        )
    }
}

private struct ReadingDayStatisticsView: View {
    @EnvironmentObject private var store: ReadingStatisticsStore
    let day: String

    var body: some View {
        List {
            Section("阅读时长") {
                CompatLabeledContent("合计", value: ReadingDuration.text(store.statistics.seconds(days: [day])))
                ForEach(ReadingKind.allCases) { kind in
                    CompatLabeledContent(kind.title, value: ReadingDuration.text(store.statistics.seconds(kind: kind, days: [day])))
                }
            }
            Section("当天阅读的书") {
                ForEach(store.statistics.books.values.filter { ($0.days[day] ?? 0) > 0 }
                    .sorted { ($0.days[day] ?? 0) > ($1.days[day] ?? 0) }) { entry in
                    NavigationLink { ReadingBookStatisticsView(bookID: entry.id) } label: {
                        CompatLabeledContent(entry.book.title, value: ReadingDuration.text(entry.days[day] ?? 0))
                    }
                }
            }
        }
        .navigationTitle(day)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReadingBookStatisticsView: View {
    @EnvironmentObject private var store: ReadingStatisticsStore
    let bookID: String

    var body: some View {
        List {
            if let entry = store.statistics.books[bookID] {
                Section("书籍") {
                    Text(entry.book.title)
                    CompatLabeledContent("类型", value: entry.book.kind.title)
                    CompatLabeledContent("累计时长", value: ReadingDuration.text(entry.seconds))
                    CompatLabeledContent("最后阅读", value: entry.lastReadAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("每日记录") {
                    ForEach(entry.days.keys.sorted(by: >), id: \.self) { day in
                        CompatLabeledContent(day, value: ReadingDuration.text(entry.days[day] ?? 0))
                    }
                }
            }
        }
        .navigationTitle("书籍阅读记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 单台设备的阅读时长；本机可在这里修改显示名称。
private struct ReadingDeviceStatisticsView: View {
    @EnvironmentObject private var store: ReadingStatisticsStore
    let deviceID: String
    @State private var name = ""

    var body: some View {
        List {
            if let device = store.devices.first(where: { $0.id == deviceID }) {
                let now = Date()
                let stats = device.statistics
                Section {
                    if device.isCurrent {
                        TextField("设备名称", text: $name)
                            .submitLabel(.done)
                            .onSubmit { store.renameDevice(name) }
                    } else {
                        Text(device.name)
                    }
                    if let model = device.model { CompatLabeledContent("类型", value: model) }
                } header: {
                    Text("设备")
                } footer: {
                    if device.isCurrent { Text("名称会在下次同步后显示在其他设备上。留空恢复为设备类型。") }
                }
                Section("阅读概览") {
                    CompatLabeledContent("今日", value: ReadingDuration.text(stats.seconds(days: [ReadingStatistics.dayKey(now)])))
                    CompatLabeledContent("本周", value: ReadingDuration.text(ReadingDuration.weekSeconds(stats, at: now)))
                    CompatLabeledContent("累计", value: ReadingDuration.text(stats.seconds()))
                    CompatLabeledContent("阅读天数", value: "\(stats.readingDays) 天")
                    ForEach(ReadingKind.allCases) { kind in
                        CompatLabeledContent(kind.title, value: ReadingDuration.text(stats.seconds(kind: kind)))
                    }
                }
                Section("书籍") {
                    let books = stats.books.values.sorted { $0.seconds > $1.seconds }
                    if books.isEmpty {
                        Text("这台设备还没有阅读记录。").foregroundStyle(.secondary)
                    }
                    ForEach(books) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.book.title).lineLimit(2)
                            Text("\(entry.book.kind.title) · \(ReadingDuration.text(entry.seconds)) · 最后阅读 \(entry.lastReadAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("找不到这台设备的记录。").foregroundStyle(.secondary)
            }
        }
        .onAppear { name = store.devices.first(where: { $0.id == deviceID })?.name ?? "" }
        .onDisappear {
            if store.devices.first(where: { $0.id == deviceID })?.isCurrent == true { store.renameDevice(name) }
        }
        .navigationTitle("设备阅读记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func readingKindColor(_ kind: ReadingKind) -> Color {
    switch kind {
    case .epub: NoveliaStyle.brandGreen
    case .txt: .orange
    case .online: .blue
    }
}

/// iOS 17 保留 Swift Charts 的点选；iOS 16 用拖动选日期；iOS 15 用手绘柱状图。
private struct ReadingDailyTrendChart: View {
    let dates: [Date]
    let calendar: Calendar
    let statistics: ReadingStatistics
    @Binding var selectedDay: String?

    var body: some View {
        if #available(iOS 16, *) {
            ReadingDailyTrendChartNative(dates: dates, calendar: calendar, statistics: statistics, selectedDay: $selectedDay)
        } else {
            ReadingDailyTrendBars(dates: dates, calendar: calendar, statistics: statistics, selectedDay: $selectedDay)
        }
    }
}

@available(iOS 16, *)
private struct ReadingDailyTrendChartNative: View {
    let dates: [Date]
    let calendar: Calendar
    let statistics: ReadingStatistics
    @Binding var selectedDay: String?

    var body: some View {
        let chart = Chart {
            ForEach(dates, id: \.self) { date in
                ForEach(ReadingKind.allCases) { kind in
                    let day = ReadingStatistics.dayKey(date, calendar: calendar)
                    BarMark(x: .value("日期", day),
                            y: .value("分钟", statistics.seconds(kind: kind, days: [day]) / 60))
                        .foregroundStyle(by: .value("类型", kind.title))
                }
            }
        }
        .chartForegroundStyleScale(["EPUB": readingKindColor(.epub), "TXT": readingKindColor(.txt), "在线阅读": readingKindColor(.online)])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let day = value.as(String.self) {
                        Text(String(day.suffix(5)))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxisLabel("分钟")
        .frame(height: 210)

        if #available(iOS 17, *) {
            chart.chartXSelection(value: $selectedDay)
        } else {
            chart.chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if let day: String = proxy.value(atX: value.location.x) {
                                selectedDay = day
                            }
                        })
                }
            }
        }
    }
}

/// iOS 15 没有 Swift Charts。柱宽按天数平分，点按一天写入与图表点选相同的日期。
private struct ReadingDailyTrendBars: View {
    let dates: [Date]
    let calendar: Calendar
    let statistics: ReadingStatistics
    @Binding var selectedDay: String?

    var body: some View {
        let days = dates.map { ReadingStatistics.dayKey($0, calendar: calendar) }
        let totals = days.map { day in
            ReadingKind.allCases.reduce(0.0) { $0 + statistics.seconds(kind: $1, days: [day]) / 60 }
        }
        let maxValue = max(totals.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    Button { selectedDay = day } label: {
                        stackedBar(day: day, total: totals[index], maxValue: maxValue, selected: selectedDay == day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day)
                }
            }
            .frame(height: 180)
            HStack(spacing: 10) {
                ForEach(ReadingKind.allCases) { kind in
                    HStack(spacing: 4) {
                        Circle().fill(readingKindColor(kind)).frame(width: 7, height: 7)
                        Text(kind.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 210)
    }

    private func stackedBar(day: String, total: Double, maxValue: Double, selected: Bool) -> some View {
        let height = max(2, CGFloat(total / maxValue) * 160)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ForEach(Array(ReadingKind.allCases.reversed())) { kind in
                    let minutes = statistics.seconds(kind: kind, days: [day]) / 60
                    Rectangle()
                        .fill(readingKindColor(kind))
                        .frame(height: total > 0 ? height * CGFloat(minutes / total) : 0)
                }
            }
            .frame(height: height)
            .overlay(Rectangle().stroke(selected ? Color.primary : .clear, lineWidth: 1))
        }
    }
}
