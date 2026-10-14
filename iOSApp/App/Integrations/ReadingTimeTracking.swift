import SwiftUI

/// 阅读页面的生命周期适配，消费 Root 注入的计时控制器；视图状态持有当前会话 ID。
/// 仅在页面可见、正文就绪、App 前台且记录开启时计时，退出或关闭后结束会话。
private struct ReadingTimeModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: ReadingActivityController
    @State private var sessionID = UUID()
    @State private var visible = false
    private var recorder: ReadingActivityController { store }
    let book: ReadingBook
    let ready: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; recorder.end(id: sessionID) }
            .onChange(of: scenePhase) { _, _ in update() }
            .onChange(of: ready) { _, _ in update() }
            .onChange(of: store.isRecordingEnabled) { _, _ in update() }
            // 定期保存检查点；任务条件变化会取消循环，不能在后台继续累计。
            .task(id: visible && ready && scenePhase == .active && store.isRecordingEnabled) {
                guard visible && ready && scenePhase == .active && store.isRecordingEnabled else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard !Task.isCancelled else { return }
                    recorder.checkpoint(id: sessionID)
                }
            }
    }

    private func update() {
        if visible && ready && scenePhase == .active && store.isRecordingEnabled {
            recorder.begin(id: sessionID, book: book)
        } else {
            recorder.end(id: sessionID)
        }
    }
}

extension View {
    /// 阅读器只发送书籍与就绪状态，具体记录实现由 App 组装选择。
    func trackReadingTime(_ book: ReadingBook, ready: Bool) -> some View {
        modifier(ReadingTimeModifier(book: book, ready: ready))
    }
}

