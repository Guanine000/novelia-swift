// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UIKit
import Combine

/// 由 NoveliaApp 持有的组装入口：统一创建配置、账号、API 和本地服务并供 Root 注入。
/// 开发替换必须显式提供完整服务集合，页面与 Store 不自行选择生产客户端。
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

    /// 生产组装保留小说/论坛独立会话；API 每次读取账号使用的同一凭据存储，避免令牌快照过期。
    static func novelia(configuration: APIConfiguration = .production,
                        session: URLSession = .shared) -> AppServices {
        // 小说与论坛续期使用同一刷新 Cookie，共用一个队列逐个执行。
        let refreshQueue = SerialAsyncGate()
        let account = AccountAuthStore(configuration: configuration, session: session, refreshQueue: refreshQueue)
        let forum = ForumAuthStore(configuration: configuration, session: session, refreshQueue: refreshQueue)
        let api = APIServiceCollection.novelia(
            configuration: configuration, session: session,
            novelToken: { [store = account.tokenStore] in store.read() },
            forumToken: { [store = forum.tokenStore] in store.read() })
        return AppServices(configuration: configuration, api: api, account: account, forumAccount: forum)
    }
}

/// 由 AppServices 持有的本地状态所有者；阅读器、书库、统计与同步使用同一套实例。
/// 进度与阅读设置共用注入的偏好存储，同步通过 App 适配访问接口，不新建第二套状态。
@MainActor
final class LocalAppServices {
    let positions: ReadingPositionStore
    let readerSettings: ReaderSettings
    let recording: ReadingActivityController
    let statistics: ReadingStatisticsStore
    let library: LibraryStateStore
    let sync: WebDAVSyncStore
    /// 只在云端有文件的书；书库显示，同步更新。
    let cloudBooks: CloudBookStore

    init(defaults: UserDefaults = .standard, recorder: (any ReadingTimeRecording)? = nil) {
        let positions = ReadingPositionStore(defaults: defaults)
        self.positions = positions
        readerSettings = ReaderSettings(defaults: defaults, positions: positions)
        statistics = ReadingStatisticsStore(defaults: defaults, deviceModel: UIDevice.current.model)
        recording = ReadingActivityController(recorder: recorder ?? statistics)
        library = LibraryStateStore(positions: positions, defaults: defaults)
        let cloudBooks = CloudBookStore()
        self.cloudBooks = cloudBooks
        sync = WebDAVSyncStore(local: AppWebDAVSyncLocalState(blocked: .shared, backgrounds: .shared,
                                                           positions: positions, library: library),
                               statistics: statistics, cloudBooks: cloudBooks)
    }
}
