import CryptoKit
import Foundation

/// TXT 与 EPUB 诊断共用的关联字段。所有值都不包含原始身份信息：书籍标记
/// 是加盐哈希，盐值每次启动都会改变，因此一份导出日志可关联同一本书的
/// 解码、解析和排版过程，而标记不能用于在其他地方识别该文件。
public enum DiagnosticContext {
    /// 单调递增的毫秒时间（系统运行时间）；即使导出的时间戳取整到秒，
    /// 不同行之间的时间差仍然准确。
    public static func monotonicMilliseconds() -> Int {
        Int(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    public static var threadLabel: String {
        pthread_main_np() != 0 ? "main" : "background"
    }

    /// 用八位十六进制字符标识一次打开、导入或阅读器会话。
    public static func newTraceID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    private static let launchSalt: [UInt8] = (0..<16).map { _ in UInt8.random(in: .min ... .max) }

    /// 用八位十六进制字符标识书籍身份（内容哈希、排版身份），仅在本次启动内保持稳定。
    public static func bookTag(_ identity: String) -> String {
        var digest = SHA256()
        digest.update(data: Data(launchSalt))
        digest.update(data: Data(identity.utf8))
        return digest.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// 最近最少使用映射，同时限制条目数量和调用方定义的总成本。
/// 不保证线程安全：每个实例应限制在单个 actor 内使用。
public struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    public let countLimit: Int
    public let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var totalCost = 0

    public init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(countLimit, 1)
        self.costLimit = max(costLimit, 1)
    }

    public var count: Int { entries.count }

    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    /// 插入条目，并在任一限制超出时淘汰最近最少使用的条目；
    /// 最新条目始终保留，即使它单独就超过成本限制。
    public mutating func insert(_ value: Value, for key: Key, cost: Int = 1) {
        if let old = entries[key] { totalCost -= old.cost }
        clock += 1
        entries[key] = Entry(value: value, cost: max(cost, 0), lastUse: clock)
        totalCost += max(cost, 0)
        while entries.count > 1, entries.count > countLimit || totalCost > costLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }), oldest.key != key {
            totalCost -= oldest.value.cost
            entries[oldest.key] = nil
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }
}
