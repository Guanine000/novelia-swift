import Foundation

/// Serializes index snapshots in submission order. Background refreshes cannot overwrite later edits.
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

    /// Existing synchronous mutations retain their error/rollback contract and share write ordering.
    func writeSync<Value: Encodable & Sendable>(_ snapshot: Value, to url: URL) throws {
        try queue.sync { try Self.persist(snapshot, to: url) }
    }

    private static func persist<Value: Encodable>(_ snapshot: Value, to url: URL) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
