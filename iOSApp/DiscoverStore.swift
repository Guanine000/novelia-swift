import Combine
import Foundation

@MainActor
final class DiscoverStore: ObservableObject {
    @Published private(set) var novels: [Novel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api = NoveliaAPIClient()

    func search(query: String) async {
        isLoading = true
        errorMessage = nil
        defer {
            if !Task.isCancelled { isLoading = false }
        }

        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            try Task.checkCancellation()
            novels = try await api.searchNovels(query: query)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            novels = []
            errorMessage = error.localizedDescription
        }
    }
}
