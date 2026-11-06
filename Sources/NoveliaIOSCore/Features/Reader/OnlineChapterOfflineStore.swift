import Foundation

/// ReaderSettings拥有的磁盘缓存；actor串行化写入和清理，清理代次拒绝迟到请求重新写回。
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
    private var generation = 0
    private var flights: [String: (UUID, Task<NovelChapter, Error>)] = [:]
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
        let id = identity(book: book, chapter: listed.id, account: account), revision = generation
        let task: Task<NovelChapter, Error>, token: UUID
        if let pending = flights[id] { token = pending.0; task = pending.1 }
        else { token = UUID(); task = Task { try await service.chapter(providerId: provider, novelId: novelID, chapterId: listed.id) }; flights[id] = (token, task) }
        defer { if flights[id]?.0 == token { flights[id] = nil } }
        let chapter = try await task.value
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
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
        generation += 1
        for task in flights.values { task.1.cancel() }; flights.removeAll()
        for entry in try entries(account: account) where bookID == nil || entry.bookID == bookID {
            try FileManager.default.removeItem(at: path(entry.id))
        }
    }
}
