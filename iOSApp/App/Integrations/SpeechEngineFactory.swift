import Foundation
import SwiftUI

/// 仅生产组装注入网络合成服务；替代验证 App 不连接云端。默认本地，明确配置后才选云端。
@MainActor
final class AppSpeechEngineFactory: SpeechEngineSelecting {
    private let service: (any CloudSpeechSynthesizing)?
    private let openAIService: (any CloudSpeechSynthesizing)?
    private let store: SpeechSettingsStore
    init(service: (any CloudSpeechSynthesizing)?, openAIService: (any CloudSpeechSynthesizing)? = nil,
         defaults: UserDefaults = .standard) {
        self.service = service; self.openAIService = openAIService
        store = SpeechSettingsStore(defaults: defaults)
    }
    func refreshVoices() async throws -> [SpeechVoiceOption] {
        guard let service else { throw SpeechPreviewFailure.unavailable }
        let voices = try await service.voices()
        try Task.checkCancellation()
        store.saveEdgeVoices(voices)
        return store.edgeVoices
    }
    func preview(text: String, voice: String, rate: Double) async throws -> Data {
        try await preview(text: text, voice: voice, rate: rate, pitch: 0)
    }
    func preview(text: String, voice: String, rate: Double, pitch: Double) async throws -> Data {
        switch store.load().preferredEngine {
        case .edge:
            guard store.edgeConsentGranted, let service else { throw SpeechPreviewFailure.unavailable }
            return try await service.synthesis(text: text, voice: voice, rate: rate, pitch: pitch).data
        case .openai:
            guard let openAIService else { throw SpeechPreviewFailure.unavailable }
            let target = OpenAISpeechVoices.isValidVoice(voice) ? voice : store.load().openAIVoice
            return try await openAIService.audio(text: text, voice: target, rate: rate)
        default:
            throw SpeechPreviewFailure.unavailable
        }
    }
    func select(local: (any SpeechEngine)?, chapterCount: Int,
                chapterText: @escaping (Int) async throws -> String) -> (any SpeechEngine)? {
        select(local: local, chapterCount: chapterCount, onReadingPosition: nil, chapterText: chapterText)
    }
    func select(local: (any SpeechEngine)?, chapterCount: Int,
                onReadingPosition: ((SpeechReadingPosition?, SpeechSettings) -> Void)?,
                chapterText: @escaping (Int) async throws -> String) -> (any SpeechEngine)? {
        let settings = store.load()
        switch settings.preferredEngine {
        case .edge where store.edgeConsentGranted:
            local?.stop()
            return EdgeSpeechEngine(service: service, chapterCount: chapterCount,
                                    onReadingPosition: onReadingPosition, chapterText: chapterText)
        case .openai where openAIService != nil:
            local?.stop()
            return EdgeSpeechEngine(service: openAIService, chapterCount: chapterCount,
                                    kind: .openai,
                                    voiceIdentifier: { $0.openAIVoice },
                                    voicesProvider: { [store] in OpenAISpeechVoices.options(selected: store.load().openAIVoice) },
                                    serviceLabel: "第三方",
                                    unavailableMessage: "当前环境不提供第三方 API 朗读。",
                                    onReadingPosition: onReadingPosition, chapterText: chapterText)
        default:
            return local
        }
    }
}
