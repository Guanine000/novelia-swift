// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 只有本地文件或已解析的 TXT 才能创建；没有网络章节回调，启用预测不会触发下载。
@MainActor
struct LocalReadingTimeSource {
    let id: String
    let load: @MainActor () async throws -> ReadingTimeMetrics

    static func epub(url: URL, hash: String, spines: [Int], starts: [Int], projection: ReadingTextProjection) -> Self {
        let identity = "epub:" + hash + "|" + projection.identity + "|" + FileContentHash.sha256(Data(spines.map(String.init).joined(separator: ",").utf8))
        return Self(id: identity) {
            let task = Task.detached(priority: .utility) {
                guard url.isFileURL, try FileContentHash.sha256(url) == hash else { throw ReadingTimeError.unavailable }
                let container = try await EPUBContainer.open(fileURL: url)
                container.displayProjection = projection
                var words = [Int](), votes: [ReadingSpeedLanguage: Int] = [:]
                for spine in spines {
                    try Task.checkCancellation()
                    guard container.spine.indices.contains(spine) else { throw ReadingTimeError.unavailable }
                    let html = try await container.chapterHTML(at: spine)
                    let count = BookWordCount.count(html: html)
                    let language = ReadingSpeedLanguage.detect(BookTextSearch.plainText(html: html))
                    words.append(count); votes[language, default: 0] += count
                }
                return try ReadingTimeMetrics(words: words, chapterStarts: starts,
                    language: votes.max { $0.value < $1.value }?.key ?? .chinese)
            }
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
    }
}

/// 显示与学习各自独立开关；配置、速率窗口均只保存本机，与阅读统计和 WebDAV 无关。
@MainActor
struct ReaderRemainingTimeMenu: View {
    @ObservedObject var store: ReadingTimeEstimateStore
    var body: some View {
        Menu {
            Toggle("显示剩余时间", isOn: $store.preferences.isEnabled)
            Toggle("学习我的默读速度", isOn: $store.preferences.learnsSpeed)
            Toggle("使用手动速度", isOn: $store.preferences.usesManualSpeed)
            Picker("阅读语言", selection: $store.preferences.language) {
                ForEach(ReadingSpeedLanguage.allCases) { Text($0.title).tag($0) }
            }
            Menu("手动速度：\(Int(store.preferences.manualSpeed)) 字/词每分钟") {
                ForEach([100, 200, 300, 400, 500, 600, 800, 1_000], id: \.self) { speed in
                    Button("\(speed) 字/词每分钟") { store.preferences.manualSpeed = Double(speed) }
                }
            }
            Button("清除已学习的速度", role: .destructive) { store.clearLearning() }
        } label: { Label("剩余阅读时间", systemImage: "hourglass") }
    }
}

/// 视图会话拥有计时锚点；速率摘要由 App 注入的唯一 Store 持有。
/// 必须常驻底栏，不能跟随工具栏显隐销毁，否则每次翻页都丢失采样起点。
@MainActor
struct ReaderRemainingTimeView: View {
    @ObservedObject var store: ReadingTimeEstimateStore
    let source: LocalReadingTimeSource?
    let point: ReadingTimePoint
    let mode: String
    let active: Bool
    var isListening = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var metrics: ReadingTimeMetrics?
    @State private var loadedID: String?
    @State private var failure = false
    @State private var sampler = ReadingSpeedSampler()

    private var taskID: String { store.preferences.isEnabled ? source?.id ?? "none" : "disabled" }
    private var language: ReadingSpeedLanguage { store.language(detected: metrics?.language ?? .chinese) }
    private var isActive: Bool { active && scenePhase == .active && loadedID == source?.id }

    var body: some View {
        Group {
            if store.preferences.isEnabled, source != nil {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityLabel("按文字估算的剩余阅读时间：\(label)")
            }
        }
        .task(id: taskID) {
            sampler.reset(); metrics = nil; loadedID = nil; failure = false
            guard store.preferences.isEnabled, let source else { return }
            do {
                let loaded = try await source.load()
                try Task.checkCancellation()
                metrics = loaded; loadedID = source.id
                bootstrap()
            } catch is CancellationError {} catch { failure = true }
        }
        .onValueChange(of: point) { _, _ in observe() }
        .onValueChange(of: active) { _, _ in bootstrap() }
        .onValueChange(of: isListening) { _, _ in bootstrap() }
        .onValueChange(of: scenePhase) { _, _ in bootstrap() }
        .onValueChange(of: store.preferences) { _, _ in bootstrap() }
        .onValueChange(of: store.resetRevision) { _, _ in bootstrap() }
        .onDisappear { sampler.reset() }
    }

    private var label: String {
        if isListening { return "听书中 · 默读估算已暂停" }
        if failure { return "剩余时间暂不可用" }
        guard let metrics, loadedID == source?.id else { return "正在计算字数…" }
        guard metrics.words.indices.contains(point.resource), metrics.words[point.resource] > 0 else { return "本节无可估算文字" }
        guard let source, let speed = store.speed(book: source.id, language: language, mode: mode), speed > 0 else {
            return store.preferences.learnsSpeed ? "学习默读速度中…" : "请启用速度学习或手动速度"
        }
        guard let remaining = metrics.remaining(point),
              let chapter = ReadingTimeFormatting.duration(seconds: remaining.chapter * 60 / speed),
              let book = ReadingTimeFormatting.duration(seconds: remaining.book * 60 / speed) else { return "剩余时间暂不可用" }
        let suffix = store.preferences.usesManualSpeed ? "（手动）" : ""
        return "本章约 \(chapter) · 本卷约 \(book)\(suffix)"
    }

    private func bootstrap() {
        sampler.reset()
        var start = point; start.reason = .reset
        record(start)
    }
    private func observe() { record(point) }
    private func record(_ point: ReadingTimePoint) {
        guard store.preferences.isEnabled, store.preferences.learnsSpeed, !store.preferences.usesManualSpeed,
              let source, let metrics else { sampler.reset(); return }
        if let speed = sampler.observe(point, metrics: metrics, now: ProcessInfo.processInfo.systemUptime, active: isActive) {
            store.record(speed, book: source.id, language: language, mode: mode)
        }
    }
}
