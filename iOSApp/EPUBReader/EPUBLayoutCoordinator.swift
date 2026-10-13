import Foundation
import UIKit
import YueduCoreText
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

// MARK: - 章节排版协调
//
// 同一本书、同一章、同一组排版参数只排一次：进行中的请求共享一个任务（逐页进度
// 同步推给所有等待者），完成结果进入 LRU，重开同一本书或字号改回原值时直接复用。
// 最后一个等待者取消时底层任务才取消；预取排在当前章之后，同一时间最多一个。
// YueduCoreText 0.8.0 的 BrowserLayoutSession 是 @MainActor，排版本身只能在主线程
// 逐页执行（每页之间让路）；这里减少的是重复与过期的主线程工作量。

/// Why a chapter layout was requested (diagnostics; raw values are exported).
enum EPUBLayoutReason: String {
    case first, restore, prefetch, navigate, seek, retry
    case resize, rotate, fontChange, styleChange, themeChange, backgroundChange
}

/// Everything in a `BrowserLayoutConfig` and the chapter request that changes pagination.
struct EPUBLayoutParameters: Hashable {
    /// Bump when the reader's layout output changes for the same inputs (CSS, workarounds).
    static let layoutVersion = 1

    let renderWidth: CGFloat
    let renderHeight: CGFloat
    let rootFontSize: CGFloat
    let fontFamilies: [String]
    let lineHeight: CGFloat?
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let insets: [CGFloat]
    let textColor: [CGFloat]
    let backgroundColor: [CGFloat]
    let alignment: Int
    let aspectRatio: CGFloat
    let readerCSS: String?
    let version: Int

    init(config: BrowserLayoutConfig, aspectRatio: CGFloat, readerCSS: String?) {
        renderWidth = config.renderWidth
        renderHeight = config.renderHeight
        rootFontSize = config.rootFontSize
        fontFamilies = config.fontFamilies
        lineHeight = config.lineHeight
        lineSpacing = config.lineSpacing
        paragraphSpacing = config.paragraphSpacing
        letterSpacing = config.letterSpacing
        let i = config.contentInsets
        insets = [i.top, i.left, i.bottom, i.right]
        textColor = Self.components(config.textColor)
        backgroundColor = Self.components(config.backgroundColor)
        alignment = config.defaultTextAlignment.rawValue
        self.aspectRatio = aspectRatio
        self.readerCSS = readerCSS
        version = Self.layoutVersion
    }

    private static func components(_ color: UIColor) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }
}

/// One chapter's pages and the data derived from them, shared between page books.
struct EPUBChapterLayout {
    var pages: [PageFragments]
    var sourceText: String
    /// 每页的 DisplayList（渲染与链接命中共用，避免重复构建）。
    var displayLists: [DisplayList]
    /// 每页可点击链接区域（含 noteref 语义），页序号 → 区域集合。
    var linkRegions: [LinkInteractionRegionSet]
    /// 本章注脚文本：noteID（不含 #）→ 文本。
    var footnotes: [String: String]
}

@MainActor
final class EPUBLayoutCoordinator {
    static let shared = EPUBLayoutCoordinator()

    struct Key: Hashable {
        let bookID: String
        let spine: Int
        let parameters: EPUBLayoutParameters
    }

    enum Priority { case current, prefetch }

    enum Outcome: String {
        /// Laid out by this request.
        case executed
        /// Joined a layout already running for the same key.
        case inflight
        /// Completed layout taken from the LRU.
        case memory
    }

    struct Statistics: Equatable {
        var executed = 0
        var completed = 0
        var memoryHits = 0
        var joins = 0
        var cancelled = 0
    }

    private final class Job {
        var priority: Priority
        var waiters: [UUID: Waiter] = [:]
        var partial: EPUBChapterLayout?
        var task: Task<Void, Never>?
        var slotContinuation: CheckedContinuation<Void, Never>?
        var runningAs: Priority?
        var isFinished = false
        init(priority: Priority) { self.priority = priority }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<EPUBChapterLayout, Error>
        let observer: (EPUBChapterLayout) -> Void
    }

    private(set) var statistics = Statistics()
    private var jobs: [Key: Job] = [:]
    private var cache: LRUCache<Key, EPUBChapterLayout>
    private var queuedPrefetch: [Job] = []
    private var runningCurrent = 0
    private var runningPrefetch = 0
    private var memoryWarningObserver: NSObjectProtocol?

    /// The cost is the chapter's UTF-16 length, a proxy for its fragments and display lists.
    init(countLimit: Int = 24, costLimit: Int = 3_000_000) {
        cache = LRUCache(countLimit: countLimit, costLimit: costLimit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cache.removeAll() }
        }
    }

    var cachedLayoutCount: Int { cache.count }
    var runningJobCount: Int { jobs.count }

    /// Lays out `key` once. `observer` receives each partial layout while this request waits;
    /// `work` runs only when no completed or running layout exists for the key.
    /// Cancelling the calling task stops waiting at once; the shared layout is cancelled when
    /// no request is left waiting for it.
    func layout(key: Key, cacheable: Bool, priority: Priority,
                observer: @escaping (EPUBChapterLayout) -> Void,
                work: @escaping (_ publish: @escaping (EPUBChapterLayout) -> Void) async throws -> EPUBChapterLayout
    ) async throws -> (layout: EPUBChapterLayout, outcome: Outcome) {
        try Task.checkCancellation()
        if cacheable, let hit = cache.value(for: key) {
            statistics.memoryHits += 1
            return (hit, .memory)
        }
        let job: Job
        let outcome: Outcome
        if let running = jobs[key], !running.isFinished {
            job = running
            outcome = .inflight
            statistics.joins += 1
            if priority == .current, running.priority == .prefetch {
                running.priority = .current
                promote(running)
            }
        } else {
            job = Job(priority: priority)
            outcome = .executed
            statistics.executed += 1
            jobs[key] = job
            job.task = Task { [weak self] in
                await self?.run(job, key: key, cacheable: cacheable, work: work)
            }
        }
        let waiterID = UUID()
        let layout = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EPUBChapterLayout, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    job.waiters[waiterID] = Waiter(continuation: continuation, observer: observer)
                    if let partial = job.partial { observer(partial) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leave(job, key: key, waiterID: waiterID) }
        }
        return (layout, outcome)
    }

    func removeAll() {
        cache.removeAll()
    }

    // MARK: Jobs

    private func run(_ job: Job, key: Key, cacheable: Bool,
                     work: (_ publish: @escaping (EPUBChapterLayout) -> Void) async throws -> EPUBChapterLayout) async {
        await acquireSlot(for: job)
        let result: Result<EPUBChapterLayout, Error>
        do {
            try Task.checkCancellation()
            let layout = try await work { [weak job] partial in
                guard let job else { return }
                job.partial = partial
                for waiter in job.waiters.values { waiter.observer(partial) }
            }
            result = .success(layout)
        } catch {
            result = .failure(error)
        }
        job.isFinished = true
        if jobs[key] === job { jobs[key] = nil }
        if case .success(let layout) = result {
            statistics.completed += 1
            if cacheable { cache.insert(layout, for: key, cost: layout.sourceText.utf16.count) }
        }
        let waiters = job.waiters.values
        job.waiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(with: result) }
        // Hand the slot to a queued prefetch only after the waiters have their result.
        releaseSlot(for: job)
    }

    /// A waiter's task was cancelled: release it now; cancel the shared layout on the next
    /// turn if nobody else is waiting (a replacement request in the same turn can still join).
    private func leave(_ job: Job, key: Key, waiterID: UUID) {
        guard let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        guard job.waiters.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, job.waiters.isEmpty, !job.isFinished else { return }
            statistics.cancelled += 1
            job.task?.cancel()
            if jobs[key] === job { jobs[key] = nil }
            if let continuation = job.slotContinuation {
                job.slotContinuation = nil
                queuedPrefetch.removeAll { $0 === job }
                continuation.resume()
            }
        }
    }

    // MARK: Slots: current chapters start at once; one prefetch at a time, only when idle.

    private func acquireSlot(for job: Job) async {
        if job.priority == .current {
            runningCurrent += 1
            job.runningAs = .current
            return
        }
        if runningCurrent == 0, runningPrefetch == 0 {
            runningPrefetch += 1
            job.runningAs = .prefetch
            return
        }
        await withCheckedContinuation { continuation in
            job.slotContinuation = continuation
            queuedPrefetch.append(job)
        }
    }

    private func releaseSlot(for job: Job) {
        switch job.runningAs {
        case .current: runningCurrent -= 1
        case .prefetch: runningPrefetch -= 1
        case nil: break
        }
        job.runningAs = nil
        startQueuedPrefetchIfIdle()
    }

    private func promote(_ job: Job) {
        guard let continuation = job.slotContinuation else { return }
        job.slotContinuation = nil
        queuedPrefetch.removeAll { $0 === job }
        runningCurrent += 1
        job.runningAs = .current
        continuation.resume()
    }

    private func startQueuedPrefetchIfIdle() {
        guard runningCurrent == 0, runningPrefetch == 0, !queuedPrefetch.isEmpty else { return }
        let next = queuedPrefetch.removeFirst()
        guard let continuation = next.slotContinuation else { return }
        next.slotContinuation = nil
        runningPrefetch += 1
        next.runningAs = .prefetch
        continuation.resume()
    }
}
