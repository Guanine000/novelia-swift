import Foundation

/// 书库列表显示的全书字数。Root 持有，书库与系列页面共用；结果只是 `BookWordCountCache`
/// 的展示副本，不持久化，也不参与同步。行出现时登记，逐本在后台统计（一次一本，后登记的先算，
/// 让正在看的行优先），行消失时撤回尚未开始的请求。云端书籍本机没有文件，只读取已有缓存。
@MainActor
final class LibraryWordCountStore: ObservableObject {
    /// 文件内容哈希 → 全书字数。
    @Published private(set) var totals: [String: Int] = [:]

    private struct Request {
        let hash: String
        let fileURL: URL?
        let format: WebNovelFileFormat
    }

    private var pending: [Request] = []
    /// 本次运行中统计失败的哈希，不反复重试；重新启动 App 后再试。
    private var failed = Set<String>()
    private var worker: Task<Void, Never>?

    func total(hash: String?) -> Int? {
        hash.flatMap { totals[$0] }
    }

    func request(_ book: LibraryBook, hash: String) {
        guard totals[hash] == nil, !failed.contains(hash) else { return }
        pending.removeAll { $0.hash == hash }
        pending.append(Request(hash: hash, fileURL: book.isCloudOnly ? nil : book.fileURL, format: book.format))
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    func cancel(hash: String) {
        pending.removeAll { $0.hash == hash }
    }

    private func drain() async {
        while let request = pending.popLast() {
            guard totals[request.hash] == nil else { continue }
            let counts: BookWordCounts?
            if let fileURL = request.fileURL {
                counts = try? await BookWordCounter.counts(fileURL: fileURL, format: request.format, hash: request.hash)
            } else {
                counts = await BookWordCounter.cached(hash: request.hash)
            }
            if let counts {
                totals[request.hash] = counts.total
            } else if request.fileURL != nil {
                failed.insert(request.hash)
            }
        }
        worker = nil
    }
}
