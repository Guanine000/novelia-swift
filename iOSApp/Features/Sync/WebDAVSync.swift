import Foundation
import Network
import Security
import SwiftUI
import UIKit

/// WebDAV 同步的设置、任务与界面进度；由 `LocalAppServices` 持有唯一实例。
/// 手动同步由书库与设置页触发；自动同步由 App 集成层转交前后台、网络与本机改动事件，
/// 是否真正执行由 `WebDAVAutoSyncPolicy` 判断，两者共用同一执行路径，同一时间只跑一个同步。
@MainActor
final class WebDAVSyncStore: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: SettingsKey.WebDAV.enabled)
            if !isEnabled { cancelAutomaticSync() }
        }
    }
    @Published var address: String {
        didSet {
            UserDefaults.standard.set(address, forKey: SettingsKey.WebDAV.address)
            updateETagWarning()
        }
    }
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: SettingsKey.WebDAV.username) } }
    @Published var syncBooks: Bool { didSet { UserDefaults.standard.set(syncBooks, forKey: SettingsKey.WebDAV.syncBooks) } }
    @Published var syncTags: Bool { didSet { UserDefaults.standard.set(syncTags, forKey: SettingsKey.WebDAV.syncTags) } }
    @Published var syncBackgrounds: Bool { didSet { UserDefaults.standard.set(syncBackgrounds, forKey: SettingsKey.WebDAV.syncBackgrounds) } }
    @Published var syncFonts: Bool { didSet { UserDefaults.standard.set(syncFonts, forKey: SettingsKey.WebDAV.syncFonts) } }
    @Published var syncStatistics: Bool { didSet { UserDefaults.standard.set(syncStatistics, forKey: SettingsKey.WebDAV.syncStatistics) } }
    @Published var autoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSyncEnabled, forKey: SettingsKey.WebDAV.autoSync)
            if autoSyncEnabled { requestAutomaticSync(.foreground) } else { cancelAutomaticSync() }
        }
    }
    @Published var password: String = ""
    @Published private(set) var isSyncing = false
    @Published private(set) var progressDetail = ""
    @Published private(set) var completedUnits = 0
    @Published private(set) var totalUnits = 1
    @Published var message: String?
    /// 当前服务器上次同步时没有返回清单 ETag，设置页据此提示避免多设备同时同步。
    @Published private(set) var serverLacksETag = false

    private let local: any WebDAVSyncLocalState
    private let statistics: any ReadingStatisticsSyncing
    /// 云端书籍：同步只取回记录与封面，打开时由 `downloadCloudBook` 下载文件。
    let cloudBooks: CloudBookStore
    /// 正在按需下载的云端书籍（书库键）与进度。
    @Published private(set) var downloadingCloudBook: String?
    @Published private(set) var cloudDownloadProgress = 0.0

    private let keychainService = "cc.novelia.ios.port.webdav"
    /// 内容同步与云端删除都会写清单，经此串行执行；按需下载不写清单，不经过这里。
    private let manifestGate = WebDAVManifestWriteGate()
    /// 最近的同步阶段，用于失败提示。
    private var stage = WebDAVSyncProgress().stage

    // MARK: 自动同步状态
    private var autoState: WebDAVAutoSyncState {
        didSet {
            guard autoState != oldValue, let data = try? JSONEncoder().encode(autoState) else { return }
            UserDefaults.standard.set(data, forKey: SettingsKey.WebDAV.autoSyncState)
        }
    }
    /// 书库由 RootView 持有，集成层启动自动同步时交给本 Store。
    private var webLibrary: (any SyncBookLibrary<DownloadedWebNovel>)?
    private var wenkuLibrary: (any SyncBookLibrary<LocalWenkuEPUB>)?
    private var isAppActive = true
    private var isNetworkAvailable = true
    private var isNetworkConstrained = false
    private var pathMonitor: NWPathMonitor?
    private var automaticTask: Task<Void, Never>?
    private var pendingLocalChange: Task<Void, Never>?
    /// 同步进行中又发生本机改动时，结束后再判断一次。
    private var recheckAfterSync = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(local: any WebDAVSyncLocalState, statistics: any ReadingStatisticsSyncing, cloudBooks: CloudBookStore) {
        self.local = local
        self.statistics = statistics
        self.cloudBooks = cloudBooks
        isEnabled = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.enabled) as? Bool ?? false
        syncBooks = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncBooks) as? Bool ?? true
        syncTags = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncTags) as? Bool ?? true
        syncBackgrounds = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncBackgrounds)
        syncFonts = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncFonts)
        syncStatistics = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncStatistics)
        autoSyncEnabled = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.autoSync)
        autoState = UserDefaults.standard.data(forKey: SettingsKey.WebDAV.autoSyncState)
            .flatMap { try? JSONDecoder().decode(WebDAVAutoSyncState.self, from: $0) } ?? WebDAVAutoSyncState()
        address = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.address) ?? ""
        username = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.username) ?? ""
        password = Self.readPassword(service: keychainService) ?? ""
        updateETagWarning()
    }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func updateETagWarning() {
        let flagged = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.manifestWithoutETag)
        serverLacksETag = flagged != nil && flagged == trimmedAddress
    }

    private func recordETagSupport(lacking: Bool) {
        if lacking { UserDefaults.standard.set(trimmedAddress, forKey: SettingsKey.WebDAV.manifestWithoutETag) }
        else { UserDefaults.standard.removeObject(forKey: SettingsKey.WebDAV.manifestWithoutETag) }
        updateETagWarning()
    }

    private var options: WebDAVSyncOptions {
        WebDAVSyncOptions(books: syncBooks, tags: syncTags, backgrounds: syncBackgrounds, fonts: syncFonts)
    }

    private var hasContentOptions: Bool { options.books || options.tags || options.backgrounds || options.fonts }

    /// 立即同步：开启的清单内容，以及开启时的阅读时长。
    func sync(web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>) async {
        guard isEnabled else {
            message = "WebDAV 同步已关闭，请先在“我的 → WebDAV 同步”中开启。"
            return
        }
        guard !isSyncing else { return }
        guard hasContentOptions || syncStatistics else {
            message = "请至少开启一项同步内容。"
            return
        }
        await run(web: web, wenku: wenku, content: hasContentOptions, statistics: syncStatistics, trigger: nil)
    }

    /// 阅读时长使用独立清单；该按钮只传输统计，不触发书籍/背景文件同步。
    func syncReadingStatistics() async {
        guard isEnabled, syncStatistics else {
            message = "请先开启 WebDAV 总开关和阅读时长同步。"
            return
        }
        guard !isSyncing else { return }
        await run(web: nil, wenku: nil, content: false, statistics: true, trigger: nil)
    }

    /// 执行一次同步。`trigger` 为 nil 表示手动同步；两者都记录自动同步状态。
    /// 清单内容失败时不再同步阅读时长；阅读时长失败（如服务器不支持 ETag）不影响已完成的内容同步，
    /// 两者分别记录失败与退避。
    private func run(web: (any SyncBookLibrary<DownloadedWebNovel>)?, wenku: (any SyncBookLibrary<LocalWenkuEPUB>)?,
                     content: Bool, statistics syncsStatistics: Bool, trigger: WebDAVAutoSyncTrigger?) async {
        let options = options
        let prefix = trigger == nil ? "" : "自动"
        isSyncing = true
        message = nil
        show(WebDAVSyncProgress())
        defer {
            isSyncing = false
            finishAutomaticRun()
        }
        // 目录缓存：自动同步跳过已确认的目录检查；手动同步先清空，重新完整检查一次。失败时清空。
        let folderCache = WebDAVFolderCache(defaults: .standard)
        if trigger == nil { folderCache.clear() }
        let client: WebDAVClient
        do {
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty, !account.contains(":"), !password.isEmpty else {
                throw WebDAVSyncError.missingCredentials
            }
            try savePassword()
            client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                      username: account, password: password, folderCache: folderCache)
        } catch {
            message = prefix + "同步失败：\(error.localizedDescription)"
            return
        }

        var summary = ""
        if content, let web, let wenku {
            autoState.content.lastAttempt = Date()
            do {
                if manifestGate.isBusy { progressDetail = "正在等待云端删除完成…" }
                let result = try await manifestGate.run {
                    try await WebDAVSyncEngine.runRetryingConcurrentChange {
                        WebDAVSyncEngine(remote: client, local: local, web: web, wenku: wenku,
                                         options: options, cloud: cloudBooks) { [weak self] in self?.show($0) }
                    }
                }
                let imported = result.imported
                recordETagSupport(lacking: result.lacksETag)
                autoState.content.lastSuccess = Date()
                autoState.content.failures = 0
                autoState.content.syncedFingerprint = WebDAVAutoSyncPolicy.fingerprint(local: local, web: web, wenku: wenku,
                                                                                       options: options)
                let cloudCount = cloudBooks.webBooks.count + cloudBooks.wenkuBooks.count
                summary = (options.books ? "云端新增 \(imported) 本书；本机网络小说 \(web.books.count) 本、文库 \(wenku.books.count) 本，未下载 \(cloudCount) 本。" : "")
                    + (options.tags ? "已同步屏蔽标签。" : "") + (options.backgrounds ? "已同步阅读背景。" : "")
                    + (options.fonts ? "已同步导入字体。" : "")
                    + (result.removedLocal > 0 ? "其他设备已从云端删除 \(result.removedLocal) 本书，本机副本已一并删除。" : "")
            } catch {
                if isCancellation(error) { cancelled(prefix) } else {
                    folderCache.clear()
                    autoState.content.failures += 1
                    let code = (error as? URLError).map { "（网络错误 \($0.code.rawValue)）" } ?? ""
                    message = prefix + "同步失败（\(stage)）\(code)：\(error.localizedDescription)"
                }
                return
            }
        }

        if syncsStatistics {
            autoState.statistics.lastAttempt = Date()
            stage = "同步阅读时长"
            progressDetail = "正在合并多设备阅读统计…"
            if !content {
                completedUnits = 0
                totalUnits = 1
            }
            do {
                if !content {
                    try await client.verifyConnection()
                    try await client.prepareFolders()
                }
                // 手动同步不用缓存，重新读取全部设备文件。
                let saved = trigger == nil ? nil : loadStatisticsCache()
                let cache = saved?.server == client.serverKey ? saved! : ReadingStatisticsSyncCache(server: client.serverKey)
                let (merged, updatedCache) = try await ReadingStatisticsSynchronizer(remote: client)
                    .sync(statistics.syncSnapshot(), deviceID: statistics.syncDeviceID, cache: cache)
                statistics.applySynced(merged)
                saveStatisticsCache(updatedCache)
                autoState.statistics.lastSuccess = Date()
                autoState.statistics.failures = 0
                autoState.statistics.syncedFingerprint = WebDAVAutoSyncPolicy.fingerprint(statistics: statistics.syncSnapshot())
                completedUnits = totalUnits
                progressDetail = "同步完成"
                summary += content ? "已合并阅读时长。" : "已合并各设备阅读统计。"
            } catch {
                if isCancellation(error) {
                    cancelled(prefix)
                    return
                }
                folderCache.clear()
                autoState.statistics.failures += 1
                let failure = "阅读时长同步失败：\(error.localizedDescription)"
                message = content ? prefix + "同步完成：" + summary + failure : prefix + failure
                return
            }
        }
        message = content ? prefix + "同步完成：" + summary : prefix + "阅读时长同步完成，" + summary
    }

    private func loadStatisticsCache() -> ReadingStatisticsSyncCache? {
        UserDefaults.standard.data(forKey: SettingsKey.WebDAV.statisticsCache)
            .flatMap { try? JSONDecoder().decode(ReadingStatisticsSyncCache.self, from: $0) }
    }

    /// 只在统计已套用到本机后保存，保证缓存记下的设备版本都已合并进本机数据。
    private func saveStatisticsCache(_ cache: ReadingStatisticsSyncCache) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: SettingsKey.WebDAV.statisticsCache)
        }
    }

    // MARK: 云端书籍

    /// 从云端删除书籍（书库键）：移除书目与不再引用的文件并记下删除时间，其他设备之后不会再上传或恢复它们。
    /// 正在同步时等同步写完清单后再执行，避免同步写回旧清单使删除的书重新出现。返回实际从云端清单移除的书数。
    @discardableResult
    func deleteFromCloud(keys: Set<String>) async throws -> Int {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !account.isEmpty, !account.contains(":"), !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }
        let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                      username: account, password: password,
                                      folderCache: WebDAVFolderCache(defaults: .standard))
        let removed = try await manifestGate.run { try await WebDAVCloudBookDeleter.delete(keys, from: client) }
        cloudBooks.remove(keys: keys)
        return removed
    }

    /// 下载云端书籍的全部文件并导入书库，成功后移除云端记录。与同步互不阻塞；同一时间只下载一本。
    func downloadCloudBook(key: String, web: any SyncBookLibrary<DownloadedWebNovel>,
                           wenku: any SyncBookLibrary<LocalWenkuEPUB>) async throws {
        guard downloadingCloudBook == nil else { return }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !account.isEmpty, !account.contains(":"), !password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }
        downloadingCloudBook = key
        cloudDownloadProgress = 0
        defer { downloadingCloudBook = nil }
        let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                      username: account, password: password,
                                      folderCache: WebDAVFolderCache(defaults: .standard))
        let progress: (Int, Int) -> Void = { [weak self] done, total in
            self?.cloudDownloadProgress = Double(done) / Double(max(total, 1))
        }
        if let book = cloudBooks.webBooks.first(where: { "web:\($0.record.id)" == key }) {
            let files = try await WebDAVCloudBookDownloader.download(book.assets, from: client, onProgress: progress)
            defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
            try web.restoreFromSync(book.record, files: files)
            cloudBooks.remove(webID: book.record.id)
        } else if let book = cloudBooks.wenkuBooks.first(where: { "wenku:\($0.record.id.uuidString)" == key }) {
            let files = try await WebDAVCloudBookDownloader.download(book.assets, from: client, onProgress: progress)
            defer { files.values.forEach { try? FileManager.default.removeItem(at: $0) } }
            try wenku.restoreFromSync(book.record, files: files)
            cloudBooks.remove(wenkuID: book.record.id)
        } else {
            throw WebDAVSyncError.invalidAsset
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func cancelled(_ prefix: String) {
        progressDetail = "已取消同步"
        message = prefix + "同步已取消。已完成的文件不会回滚；远端目录清单只在最后阶段写入。"
    }

    // MARK: 自动同步

    /// 由 App 集成层在根视图出现时调用一次；之后开始响应前后台、网络和本机改动。
    func startAutomaticSync(web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>) {
        webLibrary = web
        wenkuLibrary = wenku
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let constrained = path.isConstrained
                Task { @MainActor in self?.networkDidChange(available: available, constrained: constrained) }
            }
            monitor.start(queue: DispatchQueue(label: "cc.novelia.webdav.network", qos: .utility))
            pathMonitor = monitor
        }
        requestAutomaticSync(.foreground)
    }

    func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppActive = true
            requestAutomaticSync(.foreground)
        case .background:
            isAppActive = false
            pendingLocalChange?.cancel()
            pendingLocalChange = nil
            // 正在进行的同步也申请后台时间，让它尽量完成。
            if isSyncing { beginBackgroundTime() } else { requestAutomaticSync(.background) }
        default:
            break
        }
    }

    /// 本机书库或标签有变化：合并一段时间内的连续改动后再判断是否推送。
    func localStateDidChange() {
        guard autoSyncEnabled, isEnabled, isAppActive else { return }
        pendingLocalChange?.cancel()
        pendingLocalChange = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WebDAVAutoSyncPolicy.localChangeDelay))
            guard !Task.isCancelled else { return }
            self?.pendingLocalChange = nil
            self?.requestAutomaticSync(.localChange)
        }
    }

    /// 取消正在进行的自动同步和等待中的延迟推送；手动同步由发起的页面自行取消。
    func cancelAutomaticSync() {
        pendingLocalChange?.cancel()
        pendingLocalChange = nil
        automaticTask?.cancel()
        recheckAfterSync = false
    }

    private func networkDidChange(available: Bool, constrained: Bool) {
        let restored = available && !isNetworkAvailable
        isNetworkAvailable = available
        isNetworkConstrained = constrained
        if restored && isAppActive { requestAutomaticSync(.networkRestored) }
    }

    private func requestAutomaticSync(_ trigger: WebDAVAutoSyncTrigger) {
        guard autoSyncEnabled, isEnabled, let web = webLibrary, let wenku = wenkuLibrary else { return }
        guard !isSyncing else {
            if trigger == .localChange { recheckAfterSync = true }
            return
        }
        // 断网时等网络恢复；低数据模式下不自动传输。凭据不完整时静默跳过，手动同步会给出提示。
        guard isNetworkAvailable, !isNetworkConstrained, hasCredentials else { return }
        let content = hasContentOptions && WebDAVAutoSyncPolicy.shouldSync(
            trigger, part: autoState.content,
            fingerprint: WebDAVAutoSyncPolicy.fingerprint(local: local, web: web, wenku: wenku, options: options))
        // 本机改动事件只来自书库与标签，阅读时长由前后台切换与网络恢复带上。
        let statistics = syncStatistics && trigger != .localChange && WebDAVAutoSyncPolicy.shouldSync(
            trigger, part: autoState.statistics,
            fingerprint: WebDAVAutoSyncPolicy.fingerprint(statistics: self.statistics.syncSnapshot()))
        guard content || statistics else { return }
        if !isAppActive { beginBackgroundTime() }
        automaticTask = Task { [weak self] in
            await self?.run(web: web, wenku: wenku, content: content, statistics: statistics, trigger: trigger)
            self?.automaticTask = nil
        }
    }

    private var hasCredentials: Bool {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return !account.isEmpty && !account.contains(":") && !password.isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finishAutomaticRun() {
        endBackgroundTime()
        if recheckAfterSync && isAppActive {
            recheckAfterSync = false
            localStateDidChange()
        }
    }

    /// 进入背景后系统只给几十秒；到期时取消自动同步。清单在最后写入，中断不会留下不一致的清单，
    /// 未推送的改动仍反映在指纹上，下次回到前台会再同步。
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WebDAVSync") { [weak self] in
            MainActor.assumeIsolated {
                self?.automaticTask?.cancel()
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func show(_ progress: WebDAVSyncProgress) {
        stage = progress.stage
        progressDetail = progress.detail
        completedUnits = progress.completedUnits
        totalUnits = progress.totalUnits
    }

    private func savePassword() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "password"]
        let value = Data(password.utf8)
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        var attributes = query
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }

    private static func readPassword(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "password",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct WebDAVSyncView: View {
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @EnvironmentObject private var webDownloads: WebNovelDownloadStore
    @EnvironmentObject private var wenkuDownloads: WenkuLocalLibraryStore

    var body: some View {
        Form {
            Section {
                Toggle("启用 WebDAV 同步", isOn: $syncStore.isEnabled)
            } footer: {
                Text("关闭后，书库中的同步操作会停止；已保存的服务器地址和凭据会保留。")
            }
            Section {
                Toggle("自动同步", isOn: $syncStore.autoSyncEnabled)
                    .disabled(!syncStore.isEnabled)
                // 自动同步依赖 iOS 给的前后台时间，不保证每次都完成，提醒用户以手动同步为主。
                Label {
                    Text("此功能不够可靠，建议多手动同步")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .listRowBackground(Color.orange.opacity(0.12))
                .accessibilityLabel("提醒：自动同步不够可靠，建议多手动同步")
            } footer: {
                Text("默认关闭。开启后，回到前台时如距上次同步超过 10 分钟会自动同步；书籍、进度、系列或标签有改动时，在离开 App 或改动停止约 1 分钟后推送。断网时等待网络恢复，低数据模式下暂停，失败后逐步延长重试间隔。阅读背景和字体随回到前台的同步带上；开启阅读时长同步时，离开 App 会推送新的阅读时长，回到前台时取回其他设备的时长。")
            }
            Section {
                Toggle("书籍同步", isOn: $syncStore.syncBooks)
                Toggle("标签同步", isOn: $syncStore.syncTags)
                Toggle("阅读背景同步", isOn: $syncStore.syncBackgrounds)
                Toggle("导入字体同步", isOn: $syncStore.syncFonts)
            } header: {
                Text("同步内容")
            } footer: {
                Text("书籍同步上传本机书籍，并取回其他设备的书籍记录、EPUB 封面、阅读进度和书库系列，其他设备的书在打开时才下载；标签同步包含屏蔽与解除屏蔽记录。背景包含浅深色颜色及竖横屏图片；字体同步仅包含导入的字体文件，请确认字体许可允许同步。可独立开启，关闭的内容会保留在云端，不参与本次同步。")
            }
            .disabled(syncStore.isSyncing)
            Section {
                Toggle("阅读时长同步", isOn: $syncStore.syncStatistics)
                Button {
                    Task { await syncStore.syncReadingStatistics() }
                } label: {
                    Label("同步阅读时长", systemImage: "clock.arrow.circlepath")
                }
                .disabled(syncStore.isSyncing || !syncStore.isEnabled || !syncStore.syncStatistics)
            } header: {
                Text("阅读时长")
            } footer: {
                Text("默认关闭。使用下方服务器设置合并各设备的每日与逐书时长；开启后“立即同步”和自动同步都会包含阅读时长，重复同步不会重复累计。每台设备只写自己的统计文件，可在“阅读统计”中按设备查看。关闭记录也可同步已有统计。")
            }
            .disabled(syncStore.isSyncing)
            Section {
                TextField("https://example.com/dav/", text: $syncStore.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $syncStore.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码或应用密码", text: $syncStore.password)
                if syncStore.serverLacksETag {
                    Label {
                        Text("此服务器不提供 ETag，无法发现多台设备同时同步造成的冲突，后同步的设备会覆盖先同步的书目改动。请避免多台设备同时同步。")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("服务器")
            }
            Section {
                Button {
                    Task { await syncStore.sync(web: webDownloads, wenku: wenkuDownloads) }
                } label: {
                    if syncStore.isSyncing { ProgressView("正在同步…") }
                    else { Label("立即同步", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(syncStore.isSyncing || !syncStore.isEnabled)
                if syncStore.isSyncing {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(syncStore.completedUnits),
                                     total: Double(syncStore.totalUnits))
                            .tint(.accentColor)
                        Text(syncStore.progressDetail)
                            .font(.footnote)
                            .lineLimit(2)
                        Text("\(syncStore.completedUnits) / \(syncStore.totalUnits) · \(Int(Double(syncStore.completedUnits) / Double(syncStore.totalUnits) * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let message = syncStore.message { Text(message).font(.footnote) }
            } footer: {
                Text("使用 HTTPS WebDAV。下载文件、阅读位置和屏蔽标签保存在服务器的 NoveliaSync/v1 文件夹；冲突时按每本书的下载或导入时间保留较新版本。标签按每个标签最后修改时间合并，解除屏蔽也会同步。其他设备的书显示为“未下载”，打开时再下载；本地删除不会删除云端副本，之后会显示为未下载。请使用可信服务器：同步内容未端到端加密。用户名保存在本机设置，密码保存在钥匙串。")
            }
        }
        .navigationTitle("WebDAV 同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WebDAVSyncProgressPanel: View {
    @EnvironmentObject private var syncStore: WebDAVSyncStore
    @Environment(\.dismiss) private var dismiss
    let onCancel: () -> Void
    let onSyncAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .font(.subheadline)
            }
            if syncStore.isSyncing {
                ProgressView(value: Double(syncStore.completedUnits), total: Double(max(syncStore.totalUnits, 1)))
                    .tint(NoveliaStyle.brandGreen)
                Text(syncStore.progressDetail)
                    .font(.subheadline)
                    .lineLimit(2)
                Text("\(syncStore.completedUnits) / \(syncStore.totalUnits) · \(Int(Double(syncStore.completedUnits) / Double(max(syncStore.totalUnits, 1)) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(NoveliaStyle.muted)
                Button(role: .destructive, action: onCancel) {
                    Label("取消同步", systemImage: "xmark.circle")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(syncStore.message ?? syncStore.progressDetail)
                    .font(.subheadline)
                    .foregroundStyle(NoveliaStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onSyncAgain) {
                    Label("再次同步", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(NoveliaStyle.brandGreen)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .environmentObject(syncStore)
    }
}
