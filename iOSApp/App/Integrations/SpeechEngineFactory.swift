import Foundation
import SwiftUI

/// 仅生产组装注入网络合成服务；替代验证 App 不连接云端。默认本地，明确配置后才选云端。
@MainActor
final class AppSpeechEngineFactory: SpeechEngineSelecting {
    private let service: (any CloudSpeechSynthesizing)?
    private let store: SpeechSettingsStore
    init(service: (any CloudSpeechSynthesizing)?,
         defaults: UserDefaults = .standard) {
        self.service = service
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
        default:
            return local
        }
    }
}
