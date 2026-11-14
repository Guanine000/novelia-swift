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
    @State private var showsSyncOffer = false
    @EnvironmentObject private var store: ReadingStatisticsStore
    @State private var range = 7
    @State private var selectedDay: String?
    @State private var sortByTime = false
    private var calendar: Calendar { Calendar.current }

    private var sortedBooks: [ReadingBookStatistics] {
        store.statistics.books.values.sorted {
            if sortByTime, $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.lastReadAt != $1.lastReadAt { return $0.lastReadAt > $1.lastReadAt }
            return $0.id < $1.id
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let today = ReadingStatistics.dayKey(context.date, calendar: calendar)
            let dates = (0..<range).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: context.date) }
            List {
                Section {
                    Toggle("记录阅读时长", isOn: Binding(
                        get: { store.isRecordingEnabled },
                        set: { enabled in
                            showsSyncOffer = store.setRecordingEnabled(enabled, webDAVEnabled: syncStore.isEnabled,
                                                                        statisticsSyncEnabled: syncStore.syncStatistics)
                        }))
                } footer: {
                    Text("默认关闭。开启后记录 EPUB、TXT 和在线阅读时长；关闭后暂停新增记录，已有统计保留。WebDAV 同步开关及按钮位于“我的 → WebDAV 同步”。")
                }
                Section("阅读概览") {
                    ReadingOverviewMetrics(
                        today: ReadingDuration.text(store.statistics.seconds(days: [today])),
                        week: ReadingDuration.text(ReadingDuration.weekSeconds(store.statistics, at: context.date)),
                        total: ReadingDuration.text(store.statistics.seconds()),
                        days: "\(store.statistics.readingDays) 天",
                        usesGrid: horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
                    )
                }
                Section {
                    ForEach(store.devices) { device in
                        NavigationLink {
                            ReadingDeviceStatisticsView(deviceID: device.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: device.model == "iPad" ? "ipad" : "iphone")
                                        .foregroundStyle(.secondary)
                                    Text(device.name).lineLimit(1)
                                    if device.isCurrent {
                                        Text("本机").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text("今日 \(ReadingDuration.text(device.statistics.seconds(days: [today]))) · 累计 \(ReadingDuration.text(device.statistics.seconds()))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("设备")
                } footer: {
                    Text(store.devices.count > 1
                         ? "上方概览为所有设备合计。其他设备的时长在同步后更新。"
                         : "开启 WebDAV 阅读时长同步后，这里会显示其他设备的阅读时长。")
                }
                Section("累计类型分布") {
                    ForEach(ReadingKind.allCases) { kind in
                        let seconds = store.statistics.seconds(kind: kind)
                        let total = store.statistics.seconds()
                        VStack(alignment: .leading, spacing: 6) {
                            CompatLabeledContent(kind.title, value: ReadingDuration.text(seconds))
                            HStack {
                                ProgressView(value: total > 0 ? seconds / total : 0).tint(readingKindColor(kind))
                                Text(total > 0 ? String(format: "%.1f%%", seconds / total * 100) : "0%")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("每日趋势") {
                    Picker("时间范围", selection: $range) {
                        Text("最近 7 天").tag(7)
                        Text("最近 30 天").tag(30)
                    }.pickerStyle(.segmented)
                    ReadingDailyTrendChart(dates: dates, calendar: calendar, statistics: store.statistics, selectedDay: $selectedDay)
                    Text("点击或拖动图表选择日期，查看当天三类阅读时长。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        ReadingDayStatisticsView(day: selectedDay ?? today)
                    } label: {
                        CompatLabeledContent(selectedDay ?? today,
                                       value: ReadingDuration.text(store.statistics.seconds(days: [selectedDay ?? today])))
                    }
                }
                Section("书籍明细") {
                    Picker("排列方式", selection: $sortByTime) {
                        Text("最近阅读").tag(false)
                        Text("累计时长").tag(true)
                    }.pickerStyle(.segmented)
                    if sortedBooks.isEmpty {
                        Text("还没有阅读记录。打开一本书开始阅读后，这里会显示统计。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedBooks) { entry in
                        NavigationLink {
                            ReadingBookStatisticsView(bookID: entry.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.book.title).lineLimit(2)
                                Text("\(entry.book.kind.title) · \(ReadingDuration.text(entry.seconds))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("最后阅读：\(entry.lastReadAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("从启用此功能后开始记录。正文加载成功且阅读器处于前台时计时，无操作时继续累计；锁屏、后台或退出后暂停。当天累计达到 1 分钟计为一个阅读日。本周按系统日历计算，跨午夜按当天分配。删除书籍保留历史。开启阅读时长同步后，多设备统计随 WebDAV 同步合并，可在“设备”中分别查看；记录开关仅控制本机新增计时。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("开启阅读时长同步？", isPresented: $showsSyncOffer, titleVisibility: .visible) {
            Button("开启同步") { syncStore.syncStatistics = true }
            Button("暂不开启", role: .cancel) {}
        } message: {
            Text("你已开启 WebDAV 同步。是否同时开启阅读时长同步？之后各设备的阅读统计会随 WebDAV 同步合并。")
        }
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
    }

}

/// 宽窗口下将四项核心概览排成双列卡片网格，紧凑尺寸或无障碍大字号保持单列行视图。
private struct ReadingOverviewMetrics: View {
    let today: String
    let week: String
    let total: String
    let days: String
    let usesGrid: Bool

    var body: some View {
        if usesGrid {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 10) {
                cell("今日", value: today)
                cell("本周", value: week)
                cell("累计", value: total)
                cell("阅读天数", value: days)
            }
            .padding(.vertical, 4)
        } else {
            CompatLabeledContent("今日", value: today)
            CompatLabeledContent("本周", value: week)
            CompatLabeledContent("累计", value: total)
            CompatLabeledContent("阅读天数", value: days)
        }
    }

    private func cell(_ title: String, value: String) -> some View {
        CompatLabeledContent(title, value: value)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(NoveliaStyle.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium))
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
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
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
