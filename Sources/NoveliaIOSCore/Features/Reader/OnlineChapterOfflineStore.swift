import Foundation

/// 一次重试只刷新发起时的章节。attempt 唤醒视图任务，消费标记不会再次触发加载。
struct OnlineChapterRetry {
    private(set) var attempt = 0
    private var target: String?

    mutating func request(_ chapterID: String) {
        target = chapterID
        attempt += 1
    }

    mutating func consume(for chapterID: String) -> Bool {
        defer { target = nil }
        return target == chapterID
    }
}

/// ReaderSettings拥有的磁盘缓存；actor串行化写入和清理，清理时仅使对应账号、书籍的请求失效。
actor OnlineChapterOfflineStore {
    struct Entry: Codable, Identifiable, Sendable {
        let id: String
        let account: String
        let bookID: String
        let bookTitle: String
        let chapter: NovelChapter
        let savedAt: Date
        var bytes: Int
    }
    private let directory: URL
    /// 同章等待者共享请求。最后一个等待者退出前保留记录，清理才能拦住所有迟到的写入。
    private final class Flight {
        let account: String
        let bookID: String
        let task: Task<NovelChapter, Error>
        var waiters = 0
        var invalidated = false

        init(account: String, bookID: String, task: Task<NovelChapter, Error>) {
            self.account = account
            self.bookID = bookID
            self.task = task
        }
    }
    private var flights: [String: Flight] = [:]
    init(directory: URL) { self.directory = directory }
    private func identity(book: Novel, chapter: String, account: String) -> String {
        FileContentHash.sha256(Data("\(account)|\(book.providerId ?? "")|\(book.novelId ?? book.id)|\(chapter)".utf8))
    }
    private func path(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    func entries(account: String) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: url)), entry.account == account else { return nil }
                return entry
            }.sorted { $0.savedAt > $1.savedAt }
    }
    func cached(book: Novel, chapter: String, account: String) -> NovelChapter? {
        guard let data = try? Data(contentsOf: path(identity(book: book, chapter: chapter, account: account))),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.account == account else { return nil }
        return entry.chapter
    }
    func chapter(_ listed: NovelChapter, book: Novel, account: String, service: any NovelContentService, refresh: Bool = false) async throws -> NovelChapter {
        if !refresh, let value = cached(book: book, chapter: listed.id, account: account) { return value }
        guard let provider = book.providerId, let novelID = book.novelId else { return listed }
        let id = identity(book: book, chapter: listed.id, account: account)
        let flight: Flight
        if let pending = flights[id] {
            flight = pending
        } else {
            let task = Task { try await service.chapter(providerId: provider, novelId: novelID, chapterId: listed.id) }
            flight = Flight(account: account, bookID: book.id, task: task)
            flights[id] = flight
        }
        flight.waiters += 1
        defer {
            flight.waiters -= 1
            if flight.waiters == 0, flights[id] === flight { flights[id] = nil }
        }
        let chapter = try await flight.task.value
        try Task.checkCancellation()
        guard !flight.invalidated else { throw CancellationError() }
        let entry = Entry(id: id, account: account, bookID: book.id, bookTitle: book.title, chapter: chapter, savedAt: Date(), bytes: 0)
        var saved = entry
        saved.bytes = try JSONEncoder().encode(entry).count
        let data = try JSONEncoder().encode(saved)
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: path(id), options: .atomic)
        return chapter
    }
    func remove(account: String, bookID: String? = nil) throws {
        for (id, flight) in flights where flight.account == account && (bookID == nil || flight.bookID == bookID) {
            flight.invalidated = true
            flight.task.cancel()
            flights.removeValue(forKey: id)
        }
        for entry in try entries(account: account) where bookID == nil || entry.bookID == bookID {
            try FileManager.default.removeItem(at: path(entry.id))
        }
    }
}
