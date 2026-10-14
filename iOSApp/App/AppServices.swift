// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// App-owned composition root shared by feature views and stores.
/// Production construction is explicit; previews/tests can supply every API.
@MainActor
final class AppServices: ObservableObject {
    let performsUpdateChecks: Bool
    let local: LocalAppServices
    let configuration: APIConfiguration
    let api: APIServiceCollection
    let account: AccountAuthStore
    let forumAccount: ForumAuthStore

    init(configuration: APIConfiguration, api: APIServiceCollection,
         account: AccountAuthStore, forumAccount: ForumAuthStore, local: LocalAppServices? = nil, performsUpdateChecks: Bool = true) {
        self.performsUpdateChecks = performsUpdateChecks
        self.local = local ?? LocalAppServices()
        self.configuration = configuration
        self.api = api
        self.account = account
        self.forumAccount = forumAccount
        account.forumAuth = forumAccount
        forumAccount.accountAuth = account
    }

    static func novelia(configuration: APIConfiguration = .production,
                        session: URLSession = .shared) -> AppServices {
        let account = AccountAuthStore(configuration: configuration, session: session)
        let forum = ForumAuthStore(configuration: configuration, session: session)
        let api = APIServiceCollection.novelia(
            configuration: configuration, session: session,
            novelToken: { [store = account.tokenStore] in store.read() },
            forumToken: { [store = forum.tokenStore] in store.read() })
        return AppServices(configuration: configuration, api: api, account: account, forumAccount: forum)
    }
}

/// One owner for local feature state. Sync receives narrow interfaces to the
/// same instances used by readers, library and statistics screens.
@MainActor
final class LocalAppServices {
    let positions: ReadingPositionStore
    let readerSettings: ReaderSettings
    let recording: ReadingActivityController
    let statistics: ReadingStatisticsStore
    let library: LibraryStateStore
    let sync: WebDAVSyncStore

    init(defaults: UserDefaults = .standard, recorder: (any ReadingTimeRecording)? = nil) {
        let positions = ReadingPositionStore(defaults: defaults)
        self.positions = positions
        readerSettings = ReaderSettings(defaults: defaults, positions: positions)
        statistics = ReadingStatisticsStore(defaults: defaults)
        recording = ReadingActivityController(recorder: recorder ?? statistics)
        library = LibraryStateStore(positions: positions, defaults: defaults)
        sync = WebDAVSyncStore(local: AppWebDAVSyncLocalState(blocked: .shared, backgrounds: .shared,
                                                           positions: positions, library: library),
                               statistics: statistics)
    }
}
