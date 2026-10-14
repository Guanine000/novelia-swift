// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import Foundation

extension AppServices {
    /// Launch only in a separate validation bundle; real credentials and files are untouched.
    static func architectureValidation() -> AppServices {
        precondition(Bundle.main.bundleIdentifier == "cc.novelia.ios.architecture-validation",
                     "Architecture validation requires its dedicated application bundle.")
        if ProcessInfo.processInfo.arguments.contains("-resetArchitectureValidation") {
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            for name in ["Library", "WebNovelDownloads", "WenkuEPUB"] {
                try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
            }
        }
        URLProtocol.registerClass(ArchitectureNetworkTrap.self)
        let readium = ProcessInfo.processInfo.arguments.contains("-architectureReadium")
        UserDefaults.standard.set(readium, forKey: SettingsKey.readerEPUBReadium)
        if ProcessInfo.processInfo.arguments.contains("-architectureTXT") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("WenkuEPUB", isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = "第一章 起点\n" + String(repeating: "本地TXT验证正文，通过原有分章和Readium管线阅读。\n\n", count: 80)
            try! Data(text.utf8).write(to: directory.appendingPathComponent("architecture.txt"))
            let record = LocalWenkuEPUB(id: UUID(), title: "架构验证TXT", filename: "architecture.txt", addedAt: Date(),
                                       metadataLoaded: true, fileFormat: .txt)
            try! JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("library.json"))
        }
        let local = LocalAppServices()
        local.readerSettings.pagedTextReading = readium
        let configuration = APIConfiguration(
            novelAPI: URL(string: "https://novels.example.invalid/api/")!,
            forumAPI: URL(string: "https://forum.example.invalid/api/v1/")!,
            bookCommentsOrigin: URL(string: "https://forum.example.invalid/")!,
            novelOrigin: URL(string: "https://novels.example.invalid")!,
            forumOrigin: URL(string: "https://forum.example.invalid")!,
            authentication: try! AuthenticationConfiguration(origin: URL(string: "https://auth.example.invalid")!))
        let failure = ProcessInfo.processInfo.arguments.contains("-architectureFailFirstSearch") ? "searchNovels" : nil
        let backend = ArchitectureFixtureBackend(initialFailure: failure) { try await EPUBSampleBook.sampleURL() }
        let account = AccountAuthStore(configuration: configuration,
            tokenStore: FixtureTokenStore(username: ArchitectureFixtureBackend.username))
        let forum = ForumAuthStore(configuration: configuration,
            tokenStore: FixtureTokenStore(username: ArchitectureFixtureBackend.username))
        return AppServices(configuration: configuration, api: backend.services(), account: account,
            forumAccount: forum, local: local, performsUpdateChecks: false)
    }
}
#endif

#if DEBUG
import SwiftUI

/// Blocks external URLSession requests in the dedicated validation process.
final class ArchitectureNetworkTrap: URLProtocol {
    private static let lock = NSLock()
    private static var attempts = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return attempts }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? "") else { return false }
        return !["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

struct ArchitectureValidationIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("验证环境 · 外部请求 \(ArchitectureNetworkTrap.count)")
                .font(.caption2).padding(4).background(.regularMaterial).allowsHitTesting(false)
                .accessibilityIdentifier("architecture-validation-status")
        }
    }
}
#endif
