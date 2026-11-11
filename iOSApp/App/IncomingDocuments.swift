// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 系统通过“用 Novelia 打开”或文件分享交给 App 的文档。
/// 根视图切换到底部书库后，由书库的导入模型消费，复用复制、Kindle 确认和重复检测。
@MainActor
final class IncomingDocumentCoordinator: ObservableObject {
    @Published private(set) var pending: [URL] = []

    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        pending.append(url)
    }

    func take() -> [URL] {
        let urls = pending
        pending.removeAll()
        return urls
    }
}
