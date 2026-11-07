import Foundation

/// 云端合成逐次接收当前或用户明确开启预取的下一分段，不持有账号、阅读器或持久化正文。App 注入具体网络实现。
protocol CloudSpeechSynthesizing: Sendable {
    func voices() async throws -> [SpeechVoiceOption]
    func audio(text: String, voice: String, rate: Double) async throws -> Data
    func synthesis(text: String, voice: String, rate: Double) async throws -> CloudSpeechAudio
    func synthesis(text: String, voice: String, rate: Double, pitch: Double) async throws -> CloudSpeechAudio
}

/// 只对临时传输失败作有界重试，配置/协议错误直接呈现给用户。
protocol CloudSpeechRetryableError: Error { var shouldRetry: Bool { get } }

/// 服务返回的真实句子时间轴；缺失时间轴的服务仍可播放，但不推测句子位置。
struct CloudSpeechBoundary: Equatable, Sendable {
    let time: TimeInterval
    let duration: TimeInterval
    let text: String
}
struct CloudSpeechAudio: Sendable {
    let data: Data
    let boundaries: [CloudSpeechBoundary]
}
extension CloudSpeechSynthesizing {
    func voices() async throws -> [SpeechVoiceOption] { EdgeSpeechVoices.all }
    func synthesis(text: String, voice: String, rate: Double, pitch: Double) async throws -> CloudSpeechAudio {
        try await synthesis(text: text, voice: voice, rate: rate)
    }
    func synthesis(text: String, voice: String, rate: Double) async throws -> CloudSpeechAudio {
        CloudSpeechAudio(data: try await audio(text: text, voice: voice, rate: rate), boundaries: [])
    }
}

/// 引擎组装在 App 层；功能页面只提供本地引擎与惰性正文，不发网络请求。
@MainActor
protocol SpeechEngineSelecting: AnyObject {
    func refreshVoices() async throws -> [SpeechVoiceOption]
    func preview(text: String, voice: String, rate: Double) async throws -> Data
    func preview(text: String, voice: String, rate: Double, pitch: Double) async throws -> Data
    func select(local: (any SpeechEngine)?, chapterCount: Int,
                chapterText: @escaping (Int) async throws -> String) -> (any SpeechEngine)?
    func select(local: (any SpeechEngine)?, chapterCount: Int,
                onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)?,
                chapterText: @escaping (Int) async throws -> String) -> (any SpeechEngine)?
}
enum SpeechPreviewFailure: LocalizedError {
    case unavailable
    var errorDescription: String? { "当前环境不提供在线音色试听。" }
}
extension SpeechEngineSelecting {
    func refreshVoices() async throws -> [SpeechVoiceOption] { throw SpeechPreviewFailure.unavailable }
    func preview(text: String, voice: String, rate: Double, pitch: Double) async throws -> Data {
        try await preview(text: text, voice: voice, rate: rate)
    }
    func preview(text: String, voice: String, rate: Double) async throws -> Data { throw SpeechPreviewFailure.unavailable }
    func select(local: (any SpeechEngine)?, chapterCount: Int,
                onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)?,
                chapterText: @escaping (Int) async throws -> String) -> (any SpeechEngine)? {
        select(local: local, chapterCount: chapterCount, chapterText: chapterText)
    }
}

enum EdgeSpeechVoices {
    static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 160 && value.range(of: "^[a-z]{2,3}-[A-Z]{2}(?:-[A-Za-z0-9]+)+Neural$", options: .regularExpression) != nil
    }
    static func sanitized(_ values: [SpeechVoiceOption]) -> [SpeechVoiceOption] {
        var seen = Set<String>()
        return values.prefix(2_000).filter {
            validIdentifier($0.identifier) && !$0.name.isEmpty && $0.name.utf8.count <= 512
                && !$0.language.isEmpty && $0.language.utf8.count <= 40 && seen.insert($0.identifier).inserted
        }
    }
    static let defaultIdentifier = "zh-CN-XiaoxiaoNeural"
    // 内置常用音色，打开设置不请求微软；服务可能调整可用音色，失败时保留本地引擎入口。
    static let all: [SpeechVoiceOption] = [
        .init(identifier: defaultIdentifier, name: "晓晓", language: "zh-CN"),
        .init(identifier: "zh-CN-YunxiNeural", name: "云希", language: "zh-CN"),
        .init(identifier: "zh-TW-HsiaoChenNeural", name: "曉臻", language: "zh-TW"),
        .init(identifier: "zh-HK-HiuGaaiNeural", name: "曉佳", language: "zh-HK"),
        .init(identifier: "ja-JP-NanamiNeural", name: "七海", language: "ja-JP"),
        .init(identifier: "en-US-JennyNeural", name: "Jenny", language: "en-US")
    ]
}
