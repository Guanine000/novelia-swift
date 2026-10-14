import Foundation

/// 仅记录实际读取失败，以资源为键，避免重试产生重复警告。
struct EPUBContentDiagnostics: Sendable {
    private(set) var scannedResources = 0
    private var failures: [(path: String, reason: String)] = []

    mutating func recordSuccess(path: String) {
        scannedResources += 1
        failures.removeAll { $0.path == path }
    }

    mutating func recordFailure(path: String, reason: String) {
        if let index = failures.firstIndex(where: { $0.path == path }) {
            failures[index] = (path, reason)
        } else {
            failures.append((path, reason))
        }
    }

    var messages: [String] {
        failures.map { "书内资源读取失败：\($0.path)\n原因：\($0.reason)" }
    }
}
