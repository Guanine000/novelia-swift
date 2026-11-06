import AVFoundation
import Foundation
import MediaPlayer

// MARK: - 朗读的后台会话

/// 锁屏／耳机命令、Now Playing 信息、音频中断与路线变化、定时停止。
/// 由 `SpeechPlaybackController` 按书持有，不设全局单例；两个 App 目标共用同一实现。
/// 这里只处理平台事件与计时，朗读状态仍由控制器持有，引擎不认识本类。
/// 两份 Info.plist 开启 `UIBackgroundModes = audio` 后，系统才允许切到后台继续发声。
@MainActor
final class SpeechRemoteSession: ObservableObject {
    /// 定时停止剩余秒数；未开启或已停止时为 nil。
    @Published private(set) var remaining: TimeInterval?

    /// 由控制器接线，避免本类反向依赖朗读引擎或阅读器。
    var onPlay: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkipForward: (() -> Void)?
    var onSkipBackward: (() -> Void)?

    private var registrations: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var countdown: Timer?
    private var deadline: Date?
    private var sleepMinutes = 0
    private var bookTitle = "Novelia 朗读"
    private var currentState: SpeechPlaybackState = .idle
    private var isRegistered = false
    private var registrationID = UUID()

    /// 打开朗读面板或起播时调用；重复调用只更新书名与锁屏信息，不重复注册。
    func activate(title: String) {
        bookTitle = title.isEmpty ? "Novelia 朗读" : title
        guard !isRegistered else {
            publish(state: currentState)
            return
        }
        isRegistered = true
        registerRemoteCommands()
        registerAudioObservers()
    }

    /// 停止朗读或离开阅读器时注销，避免锁屏残留无效控件与后台通知。
    func deactivate() {
        registrationID = UUID()
        let center = MPRemoteCommandCenter.shared()
        for (command, token) in registrations { command.removeTarget(token) }
        registrations.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        cancelCountdown()
        isRegistered = false
    }

    /// 偏好变化时调整定时时长：正在朗读就按新时长重新计时，未起播则等起播时开始。
    func update(sleepTimerMinutes minutes: Int) {
        let normalized = SpeechSettings.normalizedSleepTimer(minutes)
        // 面板里改语音或语速也会写回偏好，不该因此重置已经走了多久的定时器。
        guard normalized != sleepMinutes else { return }
        sleepMinutes = normalized
        guard sleepMinutes > 0 else {
            cancelCountdown()
            return
        }
        if case .playing = currentState { startCountdown() }
    }

    func playbackStateDidChange(_ state: SpeechPlaybackState) {
        currentState = state
        publish(state: state)
        switch state {
        case .playing:
            if countdown == nil { startCountdown() }
        case .idle, .finished, .failed:
            cancelCountdown()
        case .preparing, .paused:
            // 暂停时保持墙钟倒计时，避免「暂停一会儿就绕过定时停止」。
            break
        }
    }

    // MARK: 锁屏信息

    private func publish(state: SpeechPlaybackState) {
        if case .idle = state {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // 读完或失败时保留锁屏信息（播放速率 0），让用户能从锁屏重新起播；
        // 显式 stop() 会走 deactivate() 清空并注销命令，两者不冲突。
        publishInfo(sentence: state.utterance?.text, isPlaying: state.isPlaying)
    }

    private func publishInfo(sentence: String?, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: bookTitle,
            MPMediaItemPropertyArtist: "朗读",
            MPMediaItemPropertyAlbumTitle: String((sentence ?? "Novelia 朗读").prefix(80)),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    // MARK: 远程命令

    private func registerRemoteCommands() {
        let registrationID = self.registrationID
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

        let play = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRegistered, self.registrationID == registrationID else { return }
                self.onPlay?()
            }
            return .success
        }
        registrations.append((center.playCommand, play))
        let pause = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRegistered, self.registrationID == registrationID else { return }
                self.onPause?()
            }
            return .success
        }
        registrations.append((center.pauseCommand, pause))
        let toggle = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRegistered, self.registrationID == registrationID else { return }
                self.onTogglePlayback?()
            }
            return .success
        }
        registrations.append((center.togglePlayPauseCommand, toggle))
        let next = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRegistered, self.registrationID == registrationID else { return }
                self.onSkipForward?()
            }
            return .success
        }
        registrations.append((center.nextTrackCommand, next))
        let previous = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRegistered, self.registrationID == registrationID else { return }
                self.onSkipBackward?()
            }
            return .success
        }
        registrations.append((center.previousTrackCommand, previous))
    }

    // MARK: 音频中断与路线变化

    private func registerAudioObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onPause?()
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if options.contains(.shouldResume) { onResume?() }
        @unknown default:
            break
        }
    }

    /// 拔掉耳机／断开蓝牙时暂停，避免在扬声器上继续外放。
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable { onPause?() }
    }

    // MARK: 定时停止

    private func startCountdown() {
        cancelCountdown()
        guard let end = SpeechSleepTimer.deadline(from: Date(), minutes: sleepMinutes) else { return }
        deadline = end
        remaining = end.timeIntervalSinceNow
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let deadline else {
            cancelCountdown()
            return
        }
        let left = SpeechSleepTimer.remaining(until: deadline, at: Date()) ?? 0
        remaining = left
        if left <= 0 {
            cancelCountdown()
            onStop?()
        }
    }

    private func cancelCountdown() {
        countdown?.invalidate()
        countdown = nil
        deadline = nil
        remaining = nil
    }
}
