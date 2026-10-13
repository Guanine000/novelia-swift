import CryptoKit
import Foundation

/// Correlation fields shared by TXT and EPUB diagnostics. Every value is opaque: a book tag
/// is a salted hash whose salt changes on each launch, so one exported log can relate the
/// decode, parse and layout of a book without the tag identifying the file elsewhere.
public enum DiagnosticContext {
    /// Monotonic milliseconds (system uptime); differences between lines are exact even
    /// when the export rounds timestamps to seconds.
    public static func monotonicMilliseconds() -> Int {
        Int(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    public static var threadLabel: String {
        pthread_main_np() != 0 ? "main" : "background"
    }

    /// Eight hex digits naming one open, import or reader session.
    public static func newTraceID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    private static let launchSalt: [UInt8] = (0..<16).map { _ in UInt8.random(in: .min ... .max) }

    /// Eight hex digits for a book identity (content hash, layout identity), stable within this launch only.
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

/// A least-recently-used map bounded by entry count and by a caller-defined total cost.
/// Not thread-safe: confine an instance to one actor.
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

    /// Inserts and evicts the least recently used entries over either limit; the newest
    /// entry is always kept, even when it alone exceeds the cost limit.
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
