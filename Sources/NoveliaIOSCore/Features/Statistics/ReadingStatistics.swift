import Foundation

struct ReadingBookStatistics: Codable, Equatable, Identifiable, Sendable {
    var book: ReadingBook
    var lastReadAt: Date
    var days: [String: TimeInterval] = [:]
    var id: String { book.id }
    var seconds: TimeInterval { days.values.reduce(0, +) }
}

/// 仅保存时长和书名，不保存正文或账号。日键采用记录时的本机日历日期。
struct ReadingStatistics: Codable, Equatable, Sendable {
    private(set) var books: [String: ReadingBookStatistics] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    mutating func record(book: ReadingBook, from start: Date, to end: Date,
                         duration: TimeInterval, calendar: Calendar = .current) {
        guard duration.isFinite, duration > 0 else { return }
        var entry = books[book.id] ?? ReadingBookStatistics(book: book, lastReadAt: end)
        entry.book = book
        entry.lastReadAt = max(entry.lastReadAt, end)
        let wallDuration = end.timeIntervalSince(start)
        // 系统时间跳变时仍按单调时钟累计，不把一次短会话摊到很长的日期区间。
        if wallDuration <= 0 || abs(wallDuration - duration) > 5 {
            entry.days[Self.dayKey(end, calendar: calendar), default: 0] += duration
        } else {
            var cursor = start
            while cursor < end {
                guard let dayEnd = calendar.dateInterval(of: .day, for: cursor)?.end, dayEnd > cursor else { break }
                let boundary = min(dayEnd, end)
                entry.days[Self.dayKey(cursor, calendar: calendar), default: 0] +=
                    duration * boundary.timeIntervalSince(cursor) / wallDuration
                cursor = boundary
            }
        }
        books[book.id] = entry
    }

    func seconds(kind: ReadingKind? = nil, days: Set<String>? = nil) -> TimeInterval {
        books.values.filter { kind == nil || $0.book.kind == kind }.reduce(0) { total, entry in
            total + (days.map { selected in
                selected.reduce(0) { $0 + (entry.days[$1] ?? 0) }
            } ?? entry.seconds)
        }
    }

    var dailyTotals: [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        for entry in books.values {
            for (day, seconds) in entry.days { result[day, default: 0] += seconds }
        }
        return result
    }

    /// 同一设备的单调累计值取大值，重复同步和旧快照不会使时长翻倍或倒退。
    static func mergedMaximum(_ lhs: Self, _ rhs: Self) -> Self {
        var result = lhs
        for (id, incoming) in rhs.books {
            guard var entry = result.books[id] else { result.books[id] = incoming; continue }
            if incoming.lastReadAt > entry.lastReadAt { entry.book = incoming.book }
            entry.lastReadAt = max(entry.lastReadAt, incoming.lastReadAt)
            for (day, seconds) in incoming.days { entry.days[day] = max(entry.days[day] ?? 0, seconds) }
            result.books[id] = entry
        }
        return result
    }

    /// 不同设备分别计时，展示时相加；本机计时器始终只持有本机数据。
    static func combined(_ devices: [String: Self]) -> Self {
        var result = Self()
        for snapshot in devices.values {
            for (id, incoming) in snapshot.books {
                guard var entry = result.books[id] else { result.books[id] = incoming; continue }
                if incoming.lastReadAt > entry.lastReadAt { entry.book = incoming.book }
                entry.lastReadAt = max(entry.lastReadAt, incoming.lastReadAt)
                for (day, seconds) in incoming.days { entry.days[day, default: 0] += seconds }
                result.books[id] = entry
            }
        }
        return result
    }

    var isValidForSync: Bool {
        books.allSatisfy { id, entry in
            id == entry.book.id && !id.isEmpty && entry.lastReadAt.timeIntervalSince1970.isFinite
                && entry.days.allSatisfy { day, seconds in
                    day.count == 10 && seconds.isFinite && seconds >= 0
                }
        }
    }

    var readingDays: Int { dailyTotals.values.filter { $0 >= 60 }.count }
}

/// 一个应用只拥有一个计时会话；重复开始、过期回调和切换阅读器都不会重复累计。
struct ReadingTimeTracker {
    private(set) var statistics: ReadingStatistics
    private var session: (id: UUID, book: ReadingBook, date: Date, uptime: TimeInterval)?
    init(statistics: ReadingStatistics = ReadingStatistics()) { self.statistics = statistics }

    mutating func begin(id: UUID, book: ReadingBook, date: Date, uptime: TimeInterval, calendar: Calendar = .current) {
        guard session?.id != id else { return }
        if let previous = session { end(id: previous.id, date: date, uptime: uptime, calendar: calendar) }
        session = (id, book, date, uptime)
    }

    mutating func checkpoint(id: UUID, date: Date, uptime: TimeInterval, calendar: Calendar = .current) {
        guard let current = session, current.id == id else { return }
        statistics.record(book: current.book, from: current.date, to: date,
                          duration: uptime - current.uptime, calendar: calendar)
        session = (id, current.book, date, uptime)
    }

    mutating func mergeBaseline(_ remote: ReadingStatistics) {
        statistics = .mergedMaximum(statistics, remote)
    }

    mutating func checkpointActive(date: Date, uptime: TimeInterval) {
        if let current = session { checkpoint(id: current.id, date: date, uptime: uptime) }
    }

    mutating func stop(date: Date, uptime: TimeInterval) {
        if let current = session { end(id: current.id, date: date, uptime: uptime) }
    }

    mutating func end(id: UUID, date: Date, uptime: TimeInterval, calendar: Calendar = .current) {
        guard session?.id == id else { return }
        checkpoint(id: id, date: date, uptime: uptime, calendar: calendar)
        session = nil
    }
}

/// 设备的显示信息，随阅读统计同步，用于按设备查看时长；旧版应用解码时忽略。
struct ReadingDeviceInfo: Codable, Equatable, Sendable {
    static let maxNameLength = 40

    var name: String
    /// 系统设备类型，如 iPhone、iPad。
    var model: String
    /// 名称或类型最后修改时间；不同来源的同一设备信息按此取较新者。
    var updatedAt: Date

    var isValid: Bool {
        !name.isEmpty && name.count <= Self.maxNameLength && model.count <= Self.maxNameLength
            && updatedAt.timeIntervalSince1970.isFinite
    }
}

/// 独立于书目清单，旧版书籍同步不会覆盖统计。每个安装实例保留自己的累计快照。
/// 本机缓存与旧版远端文件 `reading-statistics.json` 使用此格式；新版远端按设备分文件，见 `ReadingDeviceStatisticsFile`。
struct ReadingStatisticsSync: Codable, Equatable, Sendable {
    var version = 1
    var devices: [String: ReadingStatistics] = [:]
    /// 各设备名称与类型；可选字段，旧缓存与旧远端文件没有。
    var deviceInfo: [String: ReadingDeviceInfo]? = nil

    static func merged(_ lhs: Self, _ rhs: Self) -> Self {
        var result = lhs
        for (id, snapshot) in rhs.devices {
            result.devices[id] = .mergedMaximum(result.devices[id] ?? ReadingStatistics(), snapshot)
        }
        if let incoming = rhs.deviceInfo {
            var info = result.deviceInfo ?? [:]
            // 没有记录时直接采用：从未改名的设备名称时间为 distantPast，按“严格较新”比较会永远被丢弃。
            for (id, value) in incoming {
                guard let existing = info[id] else { info[id] = value; continue }
                if value.updatedAt > existing.updatedAt { info[id] = value }
            }
            result.deviceInfo = info
        }
        return result
    }

    var statistics: ReadingStatistics { .combined(devices) }
    var isValid: Bool {
        version == 1 && devices.allSatisfy { !$0.key.isEmpty && $0.value.isValidForSync }
            && (deviceInfo ?? [:]).allSatisfy { !$0.key.isEmpty && $0.value.isValid }
    }
}

/// 远端 `statistics/<设备 ID>.json`：每台设备只写自己的文件，读取时合并全部设备。
/// 多台设备不会写同一个文件，因此不需要条件写入，服务器也不必支持 ETag。
struct ReadingDeviceStatisticsFile: Codable, Equatable, Sendable {
    var version = 1
    var deviceID: String
    var device: ReadingDeviceInfo?
    var statistics: ReadingStatistics

    /// 设备 ID 用作远端文件名，只接受字母、数字与连字符（本机生成的是 UUID）。
    static func isValidDeviceID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
        }
    }

    var isValid: Bool {
        version == 1 && Self.isValidDeviceID(deviceID) && statistics.isValidForSync && (device?.isValid ?? true)
    }

    /// 转为可与本机缓存合并的快照。
    var snapshot: ReadingStatisticsSync {
        ReadingStatisticsSync(devices: [deviceID: statistics], deviceInfo: device.map { [deviceID: $0] })
    }
}
