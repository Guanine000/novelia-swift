import SwiftUI

/// 系列内手动检查已绑定作品的分卷目录；不下载书籍或安排后台检查。
struct WenkuSeriesNewVolumesView: View {
    let books: [LibraryBook]
    let libraryBooks: [LibraryBook]
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var auth: AccountAuthStore
    @EnvironmentObject private var state: LibraryStateStore
    @Environment(\.dismiss) private var dismiss
    @State private var outcomes: [String: Outcome] = [:]
    @State private var isChecking = false
    @State private var completed = 0
    @State private var total = 0
    @State private var checkedAccount: String?
    @State private var generation = UUID()
    @State private var checkTask: Task<Void, Never>?

    private enum Outcome { case checked(WenkuVolumeCheckReport), failed(String) }
    private var account: String { auth.offlineAccountScope }
    private var works: [WenkuNovelOutline] {
        var unique: [String: WenkuNovelOutline] = [:]
        for book in books {
            if case .wenku(let record) = book.origin, let id = record.parentWenkuID {
                unique[id] = WenkuNovelOutline(id: id, title: record.parentWenkuTitle ?? book.title)
            }
        }
        return unique.values.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }
    private func localVolumes(_ id: String) -> Set<String> {
        Set(libraryBooks.compactMap { book in
            guard !book.isCloudOnly, case .wenku(let record) = book.origin, record.parentWenkuID == id else { return nil }
            return record.volumeID
        })
    }
    var body: some View {
        CompatNavigationStack {
            List {
                Section {
                    Text("首次检查会记录当前目录；以后标出上次检查后新增的分卷。本机缺少某卷，不一定表示它是新卷。")
                    Text("只查询已绑定作品的分卷目录，不检查章节数或译文变化，不下载正文，不在后台自动检查。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if isChecking { ProgressView("正在检查 \(completed) / \(total) 部作品") }
                }
                if works.isEmpty {
                    Section {
                        Text("本系列尚无已绑定的文库作品")
                        Text("先在本地文库书籍的“更多操作 → 关联文库作品／分卷”中绑定作品，再检查新卷。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(works) { work in
                    Section(work.displayTitle) {
                        switch outcomes[work.id] {
                        case .checked(let report): result(report, work: work)
                        case .failed(let error): Text(error).foregroundStyle(NoveliaStyle.danger)
                        case nil: Text(isChecking ? "等待检查…" : "尚未检查").foregroundStyle(.secondary)
                        }
                        NavigationLink("查看文库详情") { WenkuDetailView(outline: work) }
                    }
                }
            }
            .navigationTitle("检查新卷").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("关闭") { cancel(); dismiss() }
                    Spacer()
                    if isChecking { Button("取消检查") { cancel() } }
                    else { Button("重新检查") { startCheck() }.disabled(works.isEmpty).buttonStyle(.borderedProminent) }
                }.padding().background(.regularMaterial)
            }
            .task(id: account) {
                guard checkedAccount != account else { return }
                checkedAccount = account; outcomes = [:]; startCheck()
            }
            .onDisappear { cancel() }
        }
    }
    @ViewBuilder
    private func result(_ report: WenkuVolumeCheckReport, work: WenkuNovelOutline) -> some View {
        switch report.status {
        case .initial: Text("首次检查，已记录当前 \(report.snapshot?.volumeIDs.count ?? 0) 卷")
        case .catalogChanged: Text("分卷目录类型发生变化，本次重新建立检查基准。")
        case .unavailable: Text("暂未取得可比较的分卷目录，原检查记录保留。")
        case .compared:
            Text(report.newVolumeIDs.isEmpty ? "自上次检查后暂无新卷" : "发现 \(report.newVolumeIDs.count) 个新卷")
                .foregroundStyle(report.newVolumeIDs.isEmpty ? Color.secondary : NoveliaStyle.brandGreen)
        }
        if let snapshot = report.snapshot {
            Text(snapshot.catalog == .original ? "检查范围：原文分卷" : "检查范围：译文分卷（暂无原文目录）")
                .font(.caption).foregroundStyle(.secondary)
            let local = localVolumes(work.id)
            ForEach(sorted(report.newVolumeIDs), id: \.self) { id in
                Label(local.contains(id) ? "\(id)（已在本机）" : id, systemImage: "sparkles")
            }
            let missing = snapshot.volumeIDs.subtracting(local).subtracting(report.newVolumeIDs)
            if !missing.isEmpty {
                Text("本机尚未收录／关联（不代表新卷）").font(.subheadline.weight(.medium))
                ForEach(sorted(missing), id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
            Text("本次检查：\(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func sorted(_ values: Set<String>) -> [String] {
        values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func cancel() {
        generation = UUID(); checkTask?.cancel(); checkTask = nil; isChecking = false
    }
    private func startCheck() {
        cancel()
        let requestedWorks = works, scope = account, run = UUID()
        generation = run; outcomes = [:]; completed = 0; total = requestedWorks.count
        guard !requestedWorks.isEmpty else { return }
        isChecking = true
        checkTask = Task {
            defer { if generation == run { isChecking = false; checkTask = nil } }
            for work in requestedWorks {
                guard !Task.isCancelled, generation == run, account == scope else { return }
                do {
                    let detail = try await services.api.wenku.wenkuNovel(id: work.id)
                    guard !Task.isCancelled, generation == run, account == scope else { return }
                    guard detail.id == work.id else {
                        outcomes[work.id] = .failed("返回的作品身份不匹配，未更新检查记录。")
                        completed += 1; continue
                    }
                    outcomes[work.id] = .checked(state.recordWenkuVolumeCheck(detail, account: scope))
                } catch {
                    guard !Task.isCancelled, generation == run, account == scope else { return }
                    outcomes[work.id] = .failed("检查失败：\(error.localizedDescription)")
                }
                completed += 1
            }
        }
    }
}
