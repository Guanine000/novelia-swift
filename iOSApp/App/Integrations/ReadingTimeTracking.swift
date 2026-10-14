import SwiftUI

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
    func trackReadingTime(_ book: ReadingBook, ready: Bool) -> some View {
        modifier(ReadingTimeModifier(book: book, ready: ready))
    }
}

