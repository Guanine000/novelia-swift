import Foundation

/// 在主执行域按到达顺序逐个执行异步操作，前一个结束（含抛错）后才开始下一个。
/// 用于共享外部状态、不能交错执行的操作，例如写 WebDAV 清单、使用同一刷新 Cookie 续期登录。
@MainActor
final class SerialAsyncGate {
    private(set) var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init() {}

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        // 有人等待时直接交给下一个，保持占用，避免中途被新来的操作插队。
        defer { if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() } }
        return try await operation()
    }
}
