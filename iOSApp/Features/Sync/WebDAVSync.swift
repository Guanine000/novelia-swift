import Foundation
import Security
import SwiftUI

@MainActor
final class WebDAVSyncStore: ObservableObject {
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: SettingsKey.WebDAV.enabled) } }
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: SettingsKey.WebDAV.address) } }
    @Published var username: String { didSet { UserDefaults.standard.set(username, forKey: SettingsKey.WebDAV.username) } }
    @Published var syncBooks: Bool { didSet { UserDefaults.standard.set(syncBooks, forKey: SettingsKey.WebDAV.syncBooks) } }
    @Published var syncTags: Bool { didSet { UserDefaults.standard.set(syncTags, forKey: SettingsKey.WebDAV.syncTags) } }
    @Published var syncBackgrounds: Bool { didSet { UserDefaults.standard.set(syncBackgrounds, forKey: SettingsKey.WebDAV.syncBackgrounds) } }
    @Published var syncFonts: Bool { didSet { UserDefaults.standard.set(syncFonts, forKey: SettingsKey.WebDAV.syncFonts) } }
    @Published var syncStatistics: Bool { didSet { UserDefaults.standard.set(syncStatistics, forKey: SettingsKey.WebDAV.syncStatistics) } }
    @Published var password: String = ""
    @Published private(set) var isSyncing = false
    @Published private(set) var progressDetail = ""
    @Published private(set) var completedUnits = 0
    @Published private(set) var totalUnits = 1
    @Published var message: String?

    private let local: any WebDAVSyncLocalState
    private let statistics: any ReadingStatisticsSyncing

    private let keychainService = "cc.novelia.ios.port.webdav"
    /// 最近的同步阶段，用于失败提示。
    private var stage = WebDAVSyncProgress().stage

    init(local: any WebDAVSyncLocalState, statistics: any ReadingStatisticsSyncing) {
        self.local = local
        self.statistics = statistics
        isEnabled = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.enabled) as? Bool ?? false
        syncBooks = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncBooks) as? Bool ?? true
        syncTags = UserDefaults.standard.object(forKey: SettingsKey.WebDAV.syncTags) as? Bool ?? true
        syncBackgrounds = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncBackgrounds)
        syncFonts = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncFonts)
        syncStatistics = UserDefaults.standard.bool(forKey: SettingsKey.WebDAV.syncStatistics)
        address = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.address) ?? ""
        username = UserDefaults.standard.string(forKey: SettingsKey.WebDAV.username) ?? ""
        password = Self.readPassword(service: keychainService) ?? ""
    }

    func sync(web: any SyncBookLibrary<DownloadedWebNovel>, wenku: any SyncBookLibrary<LocalWenkuEPUB>) async {
        guard isEnabled else {
            message = "WebDAV 同步已关闭，请先在“我的 → WebDAV 同步”中开启。"
            return
        }
        guard !isSyncing else { return }
        let options = WebDAVSyncOptions(books: syncBooks, tags: syncTags, backgrounds: syncBackgrounds, fonts: syncFonts)
        guard options.books || options.tags || options.backgrounds || options.fonts else {
            message = "请至少开启一项同步内容。"
            return
        }
        isSyncing = true
        message = nil
        show(WebDAVSyncProgress())
        defer { isSyncing = false }
        do {
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty, !account.contains(":"), !password.isEmpty else {
                throw WebDAVSyncError.missingCredentials
            }
            try savePassword()
            let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                          username: account, password: password)
            let engine = WebDAVSyncEngine(remote: client, local: local, web: web, wenku: wenku,
                                          options: options) { [weak self] in self?.show($0) }
            let imported = try await engine.run()
            let bookSummary = options.books ? "恢复 \(imported) 本书，网络小说 \(web.books.count) 本，文库 \(wenku.books.count) 本。" : ""
            message = "同步完成：" + bookSummary + (options.tags ? "已同步屏蔽标签。" : "") + (options.backgrounds ? "已同步阅读背景。" : "") + (options.fonts ? "已同步导入字体。" : "")
        } catch is CancellationError {
            progressDetail = "已取消同步"
            message = "同步已取消。已完成的文件不会回滚；远端目录清单只在最后阶段写入。"
        } catch let error as URLError where error.code == .cancelled {
            progressDetail = "已取消同步"
            message = "同步已取消。已完成的文件不会回滚；远端目录清单只在最后阶段写入。"
        } catch {
            let code = (error as? URLError).map { "（网络错误 \($0.code.rawValue)）" } ?? ""
            message = "同步失败（\(stage)）\(code)：\(error.localizedDescription)"
        }
    }

    /// 阅读时长使用独立清单；该按钮只传输统计，不触发书籍/背景文件同步。
    func syncReadingStatistics() async {
        guard isEnabled, syncStatistics else {
            message = "请先开启 WebDAV 总开关和阅读时长同步。"
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        message = nil
        stage = "同步阅读时长"
        progressDetail = "正在合并多设备阅读统计…"
        completedUnits = 0
        totalUnits = 1
        defer { isSyncing = false }
        do {
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty, !account.contains(":"), !password.isEmpty else { throw WebDAVSyncError.missingCredentials }
            try savePassword()
            let client = try WebDAVClient(address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                          username: account, password: password)
            try await client.verifyConnection()
            try await client.prepareFolders()
            let snapshot = statistics.syncSnapshot()
            let merged = try await ReadingStatisticsSynchronizer(remote: client).sync(snapshot)
            statistics.applySynced(merged)
            completedUnits = 1
            progressDetail = "阅读时长同步完成"
            message = "阅读时长同步完成，已合并各设备统计。"
        } catch is CancellationError {
            message = "阅读时长同步已取消。"
        } catch {
            message = "阅读时长同步失败：\(error.localizedDescription)"
        }
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
                Toggle("书籍同步", isOn: $syncStore.syncBooks)
                Toggle("标签同步", isOn: $syncStore.syncTags)
                Toggle("阅读背景同步", isOn: $syncStore.syncBackgrounds)
                Toggle("导入字体同步", isOn: $syncStore.syncFonts)
            } header: {
                Text("同步内容")
            } footer: {
                Text("书籍同步包含下载文件、阅读进度和书库系列；标签同步包含屏蔽与解除屏蔽记录。背景包含浅深色颜色及竖横屏图片；字体同步仅包含导入的字体文件，请确认字体许可允许同步。可独立开启，关闭的内容会保留在云端，不参与本次同步。")
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
                Text("默认关闭。使用下方服务器设置，手动合并各设备的每日与逐书时长；重复同步不会重复累计。关闭记录也可同步已有统计。")
            }
            .disabled(syncStore.isSyncing)
            Section("服务器") {
                TextField("https://example.com/dav/", text: $syncStore.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("用户名", text: $syncStore.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码或应用密码", text: $syncStore.password)
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
                Text("使用 HTTPS WebDAV。下载文件、阅读位置和屏蔽标签保存在服务器的 NoveliaSync/v1 文件夹；冲突时按每本书的下载或导入时间保留较新版本。标签按每个标签最后修改时间合并，解除屏蔽也会同步。书目同步为追加与恢复，本地删除不会删除云端副本，下一次同步可能重新恢复该书。请使用可信服务器：同步内容未端到端加密。用户名保存在本机设置，密码保存在钥匙串。")
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
