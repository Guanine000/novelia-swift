import SwiftUI
import Charts

@MainActor
final class ReadingStatisticsStore: ObservableObject {
    static let shared = ReadingStatisticsStore()
    private static let key = "reading.statistics.v1"
    private static let syncKey = "reading.statistics.devices.v1"
    private static let deviceKey = "reading.statistics.deviceID"
    private static let enabledKey = "reading.statistics.enabled"
    private static let everEnabledKey = "reading.statistics.everEnabled"
    @Published private(set) var statistics: ReadingStatistics
    @Published var isRecordingEnabled: Bool {
        didSet {
            defaults.set(isRecordingEnabled, forKey: Self.enabledKey)
            if isRecordingEnabled { defaults.set(true, forKey: Self.everEnabledKey) }
            else {
                tracker.stop(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                persist()
            }
        }
    }
    var hasEnabledRecording: Bool { defaults.bool(forKey: Self.everEnabledKey) }
    private let defaults: UserDefaults
    private let deviceID: String
    private var synced: ReadingStatisticsSync
    private var savedLocal: ReadingStatistics
    private var tracker: ReadingTimeTracker

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: Self.deviceKey) ?? UUID().uuidString
        deviceID = id
        defaults.set(id, forKey: Self.deviceKey)
        let saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReadingStatistics.self, from: $0) } ?? ReadingStatistics()
        var cache = defaults.data(forKey: Self.syncKey)
            .flatMap { try? JSONDecoder().decode(ReadingStatisticsSync.self, from: $0) } ?? ReadingStatisticsSync()
        let local = ReadingStatistics.mergedMaximum(saved, cache.devices[id] ?? ReadingStatistics())
        cache.devices[id] = local
        synced = cache
        savedLocal = saved
        statistics = cache.statistics
        tracker = ReadingTimeTracker(statistics: local)
        isRecordingEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// 返回是否需要在首次启用时提示开启统计同步；“暂不开启”之后不重复弹窗。
    func setRecordingEnabled(_ enabled: Bool, webDAVEnabled: Bool, statisticsSyncEnabled: Bool) -> Bool {
        let firstEnable = enabled && !hasEnabledRecording
        isRecordingEnabled = enabled
        return firstEnable && webDAVEnabled && !statisticsSyncEnabled
    }

    func begin(id: UUID, book: ReadingBook) {
        guard isRecordingEnabled else { return }
        tracker.begin(id: id, book: book, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func checkpoint(id: UUID) {
        tracker.checkpoint(id: id, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func end(id: UUID) {
        tracker.end(id: id, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
    }

    func syncSnapshot() -> ReadingStatisticsSync {
        tracker.checkpointActive(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        persist()
        var snapshot = synced
        snapshot.devices[deviceID] = tracker.statistics
        return snapshot
    }

    func applySynced(_ snapshot: ReadingStatisticsSync) {
        synced = .merged(snapshot, syncSnapshot())
        tracker.mergeBaseline(synced.devices[deviceID] ?? ReadingStatistics())
        if let data = try? JSONEncoder().encode(synced) { defaults.set(data, forKey: Self.syncKey) }
        persist()
    }

    private func persist() {
        let local = tracker.statistics
        if savedLocal != local {
            if let data = try? JSONEncoder().encode(local) { defaults.set(data, forKey: Self.key) }
            savedLocal = local
        }
        var snapshots = synced.devices
        snapshots[deviceID] = local
        let combined = ReadingStatistics.combined(snapshots)
        if statistics != combined { statistics = combined }
    }
}

private struct ReadingTimeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = ReadingStatisticsStore.shared
    @State private var sessionID = UUID()
    @State private var visible = false
    let book: ReadingBook
    let ready: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; ReadingStatisticsStore.shared.end(id: sessionID) }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: ready) { _, _ in update() }
            .onChange(of: store.isRecordingEnabled) { _, _ in update() }
            .task(id: visible && ready && scenePhase == .active && store.isRecordingEnabled) {
                guard visible && ready && scenePhase == .active && store.isRecordingEnabled else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    ReadingStatisticsStore.shared.checkpoint(id: sessionID)
                }
            }
    }

    private func update() {
        if visible && ready && scenePhase == .active && store.isRecordingEnabled {
            ReadingStatisticsStore.shared.begin(id: sessionID, book: book)
        } else {
            ReadingStatisticsStore.shared.end(id: sessionID)
        }
    }
}

extension View {
    func trackReadingTime(_ book: ReadingBook, ready: Bool) -> some View {
        modifier(ReadingTimeModifier(book: book, ready: ready))
    }
}

private enum ReadingDuration {
    static func text(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value) 秒" }
        if value < 3600 { return "\(value / 60) 分钟" }
        return "\(value / 3600) 小时 \((value % 3600) / 60) 分钟"
    }
}

struct ReadingStatisticsView: View {
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @State private var showsSyncOffer = false
    @ObservedObject private var store = ReadingStatisticsStore.shared
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
                    LabeledContent("今日", value: ReadingDuration.text(store.statistics.seconds(days: [today])))
                    LabeledContent("本周", value: ReadingDuration.text(weekSeconds(at: context.date)))
                    LabeledContent("累计", value: ReadingDuration.text(store.statistics.seconds()))
                    LabeledContent("阅读天数", value: "\(store.statistics.readingDays) 天")
                }
                Section("累计类型分布") {
                    ForEach(ReadingKind.allCases) { kind in
                        let seconds = store.statistics.seconds(kind: kind)
                        let total = store.statistics.seconds()
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(kind.title, value: ReadingDuration.text(seconds))
                            HStack {
                                ProgressView(value: total > 0 ? seconds / total : 0).tint(color(kind))
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
                    Chart {
                        ForEach(dates, id: \.self) { date in
                            ForEach(ReadingKind.allCases) { kind in
                                let day = ReadingStatistics.dayKey(date, calendar: calendar)
                                BarMark(x: .value("日期", day),
                                        y: .value("分钟", store.statistics.seconds(kind: kind, days: [day]) / 60))
                                    .foregroundStyle(by: .value("类型", kind.title))
                            }
                        }
                    }
                    .chartForegroundStyleScale(["EPUB": color(.epub), "TXT": color(.txt), "在线阅读": color(.online)])
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYAxisLabel("分钟")
                    .chartXSelection(value: $selectedDay)
                    .frame(height: 210)
                    Text("点击或拖动图表选择日期，查看当天三类阅读时长。")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        ReadingDayStatisticsView(day: selectedDay ?? today)
                    } label: {
                        LabeledContent(selectedDay ?? today,
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
                    Text("从启用此功能后开始记录。正文加载成功且阅读器处于前台时计时，无操作时继续累计；锁屏、后台或退出后暂停。当天累计达到 1 分钟计为一个阅读日。本周按系统日历计算，跨午夜按当天分配。删除书籍保留历史。开启阅读时长同步后，可在 WebDAV 页手动合并多设备统计；记录开关仅控制本机新增计时。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .alert("开启阅读时长同步？", isPresented: $showsSyncOffer) {
            Button("开启同步") { syncStore.syncStatistics = true }
            Button("暂不开启", role: .cancel) {}
        } message: {
            Text("你已开启 WebDAV 同步。是否同时开启阅读时长同步？之后可在 WebDAV 页点击按钮合并各设备的阅读统计。")
        }
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func weekSeconds(at date: Date) -> TimeInterval {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
            .map { ReadingStatistics.dayKey($0, calendar: calendar) })
        return store.statistics.seconds(days: days)
    }

    private func color(_ kind: ReadingKind) -> Color {
        switch kind {
        case .epub: NoveliaStyle.brandGreen
        case .txt: .orange
        case .online: .blue
        }
    }
}

private struct ReadingDayStatisticsView: View {
    @ObservedObject private var store = ReadingStatisticsStore.shared
    let day: String

    var body: some View {
        List {
            Section("阅读时长") {
                LabeledContent("合计", value: ReadingDuration.text(store.statistics.seconds(days: [day])))
                ForEach(ReadingKind.allCases) { kind in
                    LabeledContent(kind.title, value: ReadingDuration.text(store.statistics.seconds(kind: kind, days: [day])))
                }
            }
            Section("当天阅读的书") {
                ForEach(store.statistics.books.values.filter { ($0.days[day] ?? 0) > 0 }
                    .sorted { ($0.days[day] ?? 0) > ($1.days[day] ?? 0) }) { entry in
                    NavigationLink { ReadingBookStatisticsView(bookID: entry.id) } label: {
                        LabeledContent(entry.book.title, value: ReadingDuration.text(entry.days[day] ?? 0))
                    }
                }
            }
        }
        .navigationTitle(day)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReadingBookStatisticsView: View {
    @ObservedObject private var store = ReadingStatisticsStore.shared
    let bookID: String

    var body: some View {
        List {
            if let entry = store.statistics.books[bookID] {
                Section("书籍") {
                    Text(entry.book.title)
                    LabeledContent("类型", value: entry.book.kind.title)
                    LabeledContent("累计时长", value: ReadingDuration.text(entry.seconds))
                    LabeledContent("最后阅读", value: entry.lastReadAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("每日记录") {
                    ForEach(entry.days.keys.sorted(by: >), id: \.self) { day in
                        LabeledContent(day, value: ReadingDuration.text(entry.days[day] ?? 0))
                    }
                }
            }
        }
        .navigationTitle("书籍阅读记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}
