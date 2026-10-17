import Foundation

/// 按提交顺序串行写入索引快照，防止后台刷新覆盖随后发生的编辑。
final class LocalLibraryIndexWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Novelia.local-library.index", qos: .utility)

    func write<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.persist(snapshot, to: url)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// 现有同步修改保留错误处理与回滚约定，并遵循相同的写入顺序。
    func writeSync<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) throws {
        try queue.sync { try Self.persist(snapshot, to: url) }
    }

    private static func persist<Value: Encodable>(_ snapshot: Value, to url: URL) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}

/// 书库文件的后台复制边界，与索引队列独立；只交付完整文件，不覆盖已有目标。
final class LocalLibraryFileCopier: Sendable {
    private let queue = DispatchQueue(label: "Novelia.local-library.files", qos: .utility)

    func copy(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString)")
                let result: Result<Void, Error>
                do {
                    try FileManager.default.copyItem(at: source, to: staging)
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
