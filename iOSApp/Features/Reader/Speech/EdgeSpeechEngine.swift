import AVFoundation
import Foundation

/// 云端先合成短段音频，再由系统音频播放器播放；网络实现由 App 注入。
/// 使用服务返回的句子时间轴同步高亮与翻页；每段最多约 3KB 转义文本，会话内缓存最多 8MiB，停止即清空。
@MainActor
final class EdgeSpeechEngine: SpeechEngine {
    private(set) var preparationMessage = "正在加载朗读章节…"
    let kind: SpeechEngineKind = .edge
    var capabilities: SpeechCapabilities {
        var value: SpeechCapabilities = [.voiceSelection, .rateControl, .backgroundAudio, .chapterNavigation, .volumeControl]
        if kind == .edge { value.insert(.pitchControl) }
        if onReadingPosition != nil { value.insert(.readingFollow) }
        if !timedPositions.isEmpty { value.insert(.sentenceNavigation) }
        return value
    }
    var availableVoices: [SpeechVoiceOption] { SpeechSettingsStore().edgeVoices }
    private(set) var state: SpeechPlaybackState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((SpeechPlaybackState) -> Void)?

    private let service: (any CloudSpeechSynthesizing)?
    private let chapterCount: Int
    private var chapterText: (Int) async throws -> String
    private var settings = SpeechSettings.default
    private var chunks: [CloudSpeechText.Chunk] = []
    private var chapterIndex = 0
    private var chunkIndex = 0
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let bridge = EdgeAudioDelegate()
    private var pauseRequested = false
    private var ownsAudioSession = false
    private var cache = SpeechAudioMemoryCache()
    private var onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)?
    private var chapterUTF16Length = 0
    private var progressTimer: Timer?
    private var timedPositions: [(CloudSpeechBoundary, Range<Int>)] = []
    private var activeSentence: Int?
    private var readingPosition: SpeechReadingPosition?
    private var prefetch: (key: String, id: UUID, task: Task<CloudSpeechAudio, Error>)?
    private var audioRevision = UUID()
    private var pendingSentence: Int?
    private var failedChapter: Int?

    init(service: (any CloudSpeechSynthesizing)?, chapterCount: Int,
         onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)? = nil,
         chapterText: @escaping (Int) async throws -> String) {
        self.onReadingPosition = onReadingPosition
        self.service = service; self.chapterCount = chapterCount; self.chapterText = chapterText
        bridge.onFinish = { [weak self] player, success in
            Task { @MainActor in self?.finished(player: player, success: success) }
        }
    }

    func start(from anchor: SpeechAnchor) async {
        guard !Task.isCancelled else { return }
        stop()
        guard service != nil else { state = .failed("当前环境不提供 Edge 在线朗读。"); return }
        let generation = self.generation
        state = .preparing
        do {
            try activate()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.load(chapter: anchor.chapterIndex, progression: anchor.progression, generation: generation, sourceOffset: anchor.sourceUTF16Offset, exactVisibleStart: anchor.startsAtVisibleOffset, resumeText: anchor.resumeText)
            }
            worker = task
            await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            if self.generation == generation { worker = nil }
        } catch { state = .failed("无法启用音频播放，请重试。"); deactivate() }
    }
    func pause() {
        guard state.isPlaying || state == .preparing else { return }
        pauseRequested = true
        player?.pause(); cancelPrefetch()
        if let utterance = currentUtterance { state = .paused(utterance) }
    }
    func resume() {
        guard pauseRequested || { if case .paused = state { return true }; return false }() else { return }
        pauseRequested = false
        do { try activate() } catch { fail("无法恢复音频播放，请重试。"); return }
        if let player {
            guard player.play() else { fail("无法播放Edge音频，请重试。"); return }
            if let utterance = currentUtterance { state = .playing(utterance) }; prefetchNext()
        } else { state = .preparing }
    }
    func stop() {
        invalidate()
        chunks = []; cache.removeAll()
        deactivate(); state = .idle
    }
    func retry() -> Bool {
        guard case .failed = state, service != nil else { return false }
        invalidate()
        let generation = self.generation
        state = .preparing
        worker = Task { [weak self] in
            guard let self else { return }
            do { try self.activate() } catch { self.fail("无法启用音频播放，请重试。"); return }
            if let chapter = self.failedChapter { await self.load(chapter: chapter, progression: 0, generation: generation) }
            else { await self.prepare(generation: generation) }
        }
        return true
    }
    func skipChapter(_ delta: Int) {
        guard delta != 0, chapterCount > 0 else { return }
        let target = min(chapterCount - 1, max(0, chapterIndex + delta))
        invalidate(); chunks = []; failedChapter = target
        let generation = self.generation
        state = .preparing
        worker = Task { [weak self] in await self?.load(chapter: target, progression: 0, generation: generation) }
    }
    func skipBackward() {
        guard state.utterance != nil else { return }
        if chunkIndex == 0, (activeSentence ?? 0) == 0, !timedPositions.isEmpty { seekSentence(0); return }
        if let activeSentence, activeSentence > 0 { seekSentence(activeSentence - 1); return }
        invalidate(); chunkIndex = max(0, chunkIndex - 1); pendingSentence = -1; schedule()
    }
    func skipForward() {
        guard state.utterance != nil else { return }
        if let activeSentence, activeSentence + 1 < timedPositions.count { seekSentence(activeSentence + 1); return }
        invalidate(); chunkIndex += 1; schedule()
    }
    /// 接管现有播放器和时间轴，返回书内时不重新请求音频或重置 currentTime。
    func rebindReadingContext(to replacement: EdgeSpeechEngine) {
        chapterText = replacement.chapterText
        onReadingPosition = replacement.onReadingPosition
    }

    func update(settings: SpeechSettings) {
        let next = settings.clamped()
        if next.edgeVoiceIdentifier != self.settings.edgeVoiceIdentifier || next.rate != self.settings.rate
            || next.pitch != self.settings.pitch || next.edgePrefetchEnabled != self.settings.edgePrefetchEnabled {
            cancelPrefetch()
        }
        self.settings = next
        player?.volume = Float(next.volume)
        if state.isPlaying { prefetchNext() }
        onReadingPosition?(readingPosition, self.settings)
    }

    /// 只消费服务时间轴，不按字数估计进度；暂停时保留高亮，停止和换段时清除。
    func refreshProgress() {
        guard state.isPlaying, let player,
              let index = timedPositions.lastIndex(where: { $0.0.time <= player.currentTime }),
              activeSentence != index else { return }
        activeSentence = index
        let (boundary, range) = timedPositions[index]
        readingPosition = SpeechReadingPosition(chapterIndex: chapterIndex, sentenceRange: range,
                                               currentOffset: range.lowerBound, chapterUTF16Length: chapterUTF16Length)
        state = .playing(SpeechUtterance(text: boundary.text, chapterIndex: chapterIndex,
                                        utf16Offset: range.lowerBound, wordRange: nil, chapterUTF16Length: chapterUTF16Length))
        onReadingPosition?(readingPosition, settings)
    }
    private func seekSentence(_ index: Int) {
        guard timedPositions.indices.contains(index), let player else { return }
        player.currentTime = timedPositions[index].0.time
        activeSentence = nil
        if !state.isPlaying {
            guard player.play() else { fail("无法播放Edge音频，请重试。"); return }
            pauseRequested = false
            if let utterance = currentUtterance { state = .playing(utterance) }
        }
        refreshProgress()
    }
    private func cancelPrefetch() {
        audioRevision = UUID(); prefetch?.task.cancel(); prefetch = nil
    }
    private static func fetch(_ service: any CloudSpeechSynthesizing, text: String, voice: String, rate: Double, pitch: Double) async throws -> CloudSpeechAudio {
        do { return try await service.synthesis(text: text, voice: voice, rate: rate, pitch: pitch) }
        catch {
            guard !Task.isCancelled, (error as? any CloudSpeechRetryableError)?.shouldRetry == true else { throw error }
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()
            return try await service.synthesis(text: text, voice: voice, rate: rate, pitch: pitch)
        }
    }
    private func audioKey(text: String, voice: String, rate: Double, pitch: Double) -> String {
        voice + "\u{0}" + String(rate) + "\u{0}" + String(pitch) + "\u{0}" + text
    }
    /// 最多提前一段、最多一个预取请求；仅在同章内预取，不提前加载下一章正文。
    private func prefetchNext() {
        guard state.isPlaying, settings.edgePrefetchEnabled, let service, prefetch == nil,
              chunks.indices.contains(chunkIndex + 1) else { return }
        let text = chunks[chunkIndex + 1].text, voice = settings.edgeVoiceIdentifier, rate = settings.rate, pitch = settings.pitch
        let key = audioKey(text: text, voice: voice, rate: rate, pitch: pitch)
        guard cache.getAudio(key) == nil else { return }
        let revision = audioRevision, id = UUID()
        let task = Task { [weak self] () throws -> CloudSpeechAudio in
            do {
                let audio = try await Self.fetch(service, text: text, voice: voice, rate: rate, pitch: pitch)
                try Task.checkCancellation()
                guard let self, self.audioRevision == revision else { throw CancellationError() }
                self.cache.putAudio(audio, for: key)
                if self.prefetch?.id == id { self.prefetch = nil }
                return audio
            } catch {
                if let self, self.prefetch?.id == id { self.prefetch = nil }
                throw error
            }
        }
        prefetch = (key, id, task)
    }
    private func clearProgress() {
        progressTimer?.invalidate(); progressTimer = nil
        timedPositions = []; activeSentence = nil; readingPosition = nil
        onReadingPosition?(nil, settings)
    }

    private var currentUtterance: SpeechUtterance? {
        guard chunks.indices.contains(chunkIndex) else { return nil }
        let chunk = chunks[chunkIndex]
        if let activeSentence, timedPositions.indices.contains(activeSentence) {
            let (boundary, range) = timedPositions[activeSentence]
            return SpeechUtterance(text: boundary.text, chapterIndex: chapterIndex,
                                   utf16Offset: range.lowerBound, wordRange: nil, chapterUTF16Length: chapterUTF16Length)
        }
        return SpeechUtterance(text: chunk.text, chapterIndex: chapterIndex,
                               utf16Offset: chunk.sourceRange.lowerBound, wordRange: nil, chapterUTF16Length: chapterUTF16Length)
    }
    private func invalidate() {
        clearProgress(); cancelPrefetch(); pendingSentence = nil
        generation = UUID(); worker?.cancel(); worker = nil
        player?.delegate = nil; player?.stop(); player = nil; pauseRequested = false
    }
    private func schedule() {
        let generation = self.generation
        state = .preparing
        worker = Task { [weak self] in
            guard let self else { return }
            if self.chunks.indices.contains(self.chunkIndex) { await self.prepare(generation: generation) }
            else { await self.load(chapter: self.chapterIndex + 1, progression: 0, generation: generation) }
        }
    }
    private func load(chapter start: Int, progression: Double, generation: UUID, sourceOffset: Int? = nil, exactVisibleStart: Bool = false, resumeText: String? = nil) async {
        guard self.generation == generation, !Task.isCancelled else { return }
        var index = start
        failedChapter = start
        do {
            while index >= 0 && index < chapterCount {
                failedChapter = index
                preparationMessage = "正在加载朗读章节…"
                state = .preparing
                let text = try await chapterText(index)
                let sourceOffset = sourceOffset ?? resumeText.flatMap { SpeechText.selectedOffset($0, in: text, near: progression) }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let requestedProgression = index == start
                    ? SpeechAnchor(chapterIndex: index, progression: progression, chapterUTF16Length: text.utf16.count,
                                   startIndexHint: nil, sourceUTF16Offset: sourceOffset).resolvedProgression(length: text.utf16.count) : 0
                let chunks = await Task.detached(priority: .userInitiated) {
                    CloudSpeechText.chunks(in: text, startingAt: requestedProgression, visibleOffset: exactVisibleStart ? sourceOffset : nil)
                }.value
                guard self.generation == generation, !Task.isCancelled else { return }
                if chunks.isEmpty { index += 1; continue }
                failedChapter = nil
                self.chunks = chunks; chapterIndex = index; chapterUTF16Length = text.utf16.count
                chunkIndex = CloudSpeechText.startIndex(in: chunks, length: text.utf16.count, progression: requestedProgression)
                await prepare(generation: generation)
                return
            }
            deactivate(); state = .finished
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            fail("无法读取朗读章节，请重试。")
        }
    }
    private func prepare(generation: UUID) async {
        guard self.generation == generation, !Task.isCancelled,
              let service, let utterance = currentUtterance else { return }
        preparationMessage = "正在请求Edge语音音频…"
        state = .preparing
        let voice = settings.edgeVoiceIdentifier, rate = settings.rate, pitch = settings.pitch
        let key = audioKey(text: utterance.text, voice: voice, rate: rate, pitch: pitch)
        do {
            let audio: CloudSpeechAudio
            if let cached = cache.getAudio(key) { audio = cached }
            else {
                if let pending = prefetch, pending.key == key {
                    do { audio = try await pending.task.value }
                    catch {
                        try Task.checkCancellation()
                        guard self.generation == generation else { return }
                        audio = try await Self.fetch(service, text: utterance.text, voice: voice, rate: rate, pitch: pitch)
                    }
                } else { audio = try await Self.fetch(service, text: utterance.text, voice: voice, rate: rate, pitch: pitch) }
                guard self.generation == generation, !Task.isCancelled else { return }
                cache.putAudio(audio, for: key)
            }
            guard self.generation == generation, !Task.isCancelled else { return }
            clearProgress()
            let chunk = chunks[chunkIndex]
            let ranges = SpeechText.sourceRanges(of: audio.boundaries.map(\.text), in: chunk.text)
            timedPositions = zip(audio.boundaries, ranges).compactMap { boundary, range in
                guard let range, let source = chunk.sourceRange(for: range) else { return nil }
                return (boundary, source)
            }
            let next = try AVAudioPlayer(data: audio.data)
            next.volume = Float(settings.volume)
            next.delegate = bridge; _ = next.prepareToPlay(); player = next
            if pauseRequested { state = .paused(utterance) }
            else {
                guard next.play() else { fail("无法播放 Edge 音频，请重试。"); return }
                state = .playing(utterance)
                if let pendingSentence, !timedPositions.isEmpty {
                    self.pendingSentence = nil
                    next.currentTime = timedPositions[pendingSentence < 0 ? timedPositions.count - 1 : min(pendingSentence, timedPositions.count - 1)].0.time
                }
                refreshProgress()
            }
            prefetchNext()
            if !timedPositions.isEmpty {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshProgress() }
                }
                progressTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            // 网络适配器已将服务错误转换为不含正文/地址/令牌的本地化消息。
            if let message = (error as? LocalizedError)?.errorDescription { fail(message) }
            else { fail("Edge音频合成失败，请重试或改用本地朗读。") }
        }
    }
    private func finished(player: AVAudioPlayer, success: Bool) {
        guard self.player === player else { return }
        guard success else { fail("Edge音频播放失败，请重试。"); return }
        clearProgress(); self.player = nil; chunkIndex += 1; schedule()
    }
    private func fail(_ message: String) {
        clearProgress(); cancelPrefetch()
        player?.delegate = nil; player?.stop(); player = nil
        deactivate(); state = .failed(message)
    }
    private func activate() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try audio.setActive(true)
        ownsAudioSession = true
    }
    private func deactivate() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class EdgeAudioDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: ((AVAudioPlayer, Bool) -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?(player, flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish?(player, false) }
}
