import Foundation

/// 在后台串行读取、编码与写入索引；App 通过 LocalLibraryRepository 保持提交与发布顺序。
final class LocalLibraryIndexWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Novelia.local-library.index", qos: .utility)
    private let persist: @Sendable (Data, URL) throws -> Void

    init(persist: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.persist = persist
    }

    /// 索引解码、文件存在性检查及旧记录整理都在后台执行。损坏文件抛错保留，不能当空书库覆盖。
    func read<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL, fallback: Value,
                                           normalize: @escaping @Sendable (Value) -> Value = { $0 }) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let value = FileManager.default.fileExists(atPath: url.path)
                        ? try JSONDecoder().decode(type, from: Data(contentsOf: url)) : fallback
                    continuation.resume(returning: normalize(value))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func write<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.persist(JSONEncoder().encode(snapshot), url)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 供旧实现基线与写入顺序回归使用；App 书库提交使用异步 Repository，不调用此入口。
    func writeSync<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) throws {
        try queue.sync { try self.persist(JSONEncoder().encode(snapshot), url) }
    }
}

/// 书库文件的后台复制边界，与索引队列独立；只交付完整文件，不覆盖已有目标。
final class LocalLibraryFileCopier: Sendable {
    private let queue = DispatchQueue(label: "Novelia.local-library.files", qos: .utility)
    private let copyFile: @Sendable (URL, URL) throws -> Void

    init(copy: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        copyFile = copy
    }

    func remove(_ files: [URL]) async {
        guard !files.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                for file in files { try? FileManager.default.removeItem(at: file) }
                continuation.resume()
            }
        }
    }

    func copy(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString)")
                let result: Result<Void, Error>
                do {
                    try self.copyFile(source, staging)
                    // 同一目录移动只提交完整文件；目标已存在则失败，不删除或覆盖它。
                    try FileManager.default.moveItem(at: staging, to: destination)
                    result = .success(())
                } catch { result = .failure(error) }
                try? FileManager.default.removeItem(at: staging)
                continuation.resume(with: result)
            }
        }
    }
}

/// 书库索引的提交边界。由所属 Store 持有，串行执行读取／修改／写盘／发布；
/// 修改闭包总是读取上一笔已提交快照，等待 I/O 期间的新操作不会用旧数组覆盖它。
@MainActor
final class LocalLibraryRepository<Record: Codable & Equatable & Sendable> {
    private let url: URL
    private let writer: LocalLibraryIndexWriter
    private let normalize: @Sendable ([Record]) -> [Record]
    private let gate = SerialAsyncGate()
    private var records: [Record]?

    init(url: URL, writer: LocalLibraryIndexWriter = LocalLibraryIndexWriter(),
         normalize: @escaping @Sendable ([Record]) -> [Record] = { $0 }) {
        self.url = url
        self.writer = writer
        self.normalize = normalize
    }

    func load(publish: ([Record]) -> Void) async throws {
        try await gate.run {
            try Task.checkCancellation()
            if records == nil { records = try await writer.read([Record].self, from: url, fallback: [], normalize: normalize) }
            publish(records ?? [])
        }
    }

    @discardableResult
    func update<Value>(_ change: (inout [Record]) throws -> Value, publish: ([Record]) -> Void) async throws -> Value {
        try await gate.run {
            try Task.checkCancellation()
            if records == nil { records = try await writer.read([Record].self, from: url, fallback: [], normalize: normalize) }
            var next = records ?? []
            let result = try change(&next)
            if next != (records ?? []) {
                try Task.checkCancellation()
                try await writer.write(next, to: url)
                // 写盘已经成功时即使收到取消，也要发布同一快照，不能清理已提交书籍。
                records = next
            }
            publish(next)
            return result
        }
    }
}
