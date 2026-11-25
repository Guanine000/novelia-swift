import SwiftUI

/// 只通过已注入的正文服务取章；缓存按账号隔离，离开页面取消尚未处理的批次。
struct OfflineChapterManagementView: View {
    var novel: Novel? = nil
    @EnvironmentObject private var settings: ReaderSettings
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var auth: AccountAuthStore

    @State private var entries: [OnlineChapterOfflineStore.Entry] = []
    @State private var first = "1"
    @State private var last = "20"
    @State private var message: String?
    @State private var lastBatchHadFailures = false
    @State private var completed = 0
    @State private var total = 0
    @State private var job: Task<Void, Never>?
    @State private var running = false
    @State private var confirmingClearAll = false
    @State private var clearingAll = false
    @State private var confirmingDelete: String?
    @State private var expandsChapterList = false
    @FocusState private var focusedField: RangeField?

    private enum RangeField { case first, last }

    private var account: String { auth.offlineAccountScope }
    private var accountLabel: String { auth.username ?? "未登录（本地缓存）" }
    private var groups: [String: [OnlineChapterOfflineStore.Entry]] { Dictionary(grouping: entries, by: \.bookID) }

    /// 按占用空间降序排列，方便用户优先清理占用最大的缓存书籍。
    private var sortedGroupIDs: [String] {
        groups.keys.sorted { lhs, rhs in
            let leftBytes = groups[lhs]?.reduce(0) { $0 + $1.bytes } ?? 0
            let rightBytes = groups[rhs]?.reduce(0) { $0 + $1.bytes } ?? 0
            if leftBytes != rightBytes { return leftBytes > rightBytes }
            return lhs < rhs
        }
    }

    private var totalBytes: Int {
        entries.reduce(0) { $0 + $1.bytes }
    }

    private var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    private var range: ClosedRange<Int>? {
        guard let novel, let a = Int(first), let b = Int(last), a >= 1, b >= a, b <= novel.chapters.count, b - a < 200 else { return nil }
        return (a - 1)...(b - 1)
    }

    private var rangeHint: String? {
        guard let novel else { return nil }
        guard let a = Int(first), let b = Int(last) else { return "请输入有效的起止章号" }
        if a < 1 || b > novel.chapters.count || b < a { return "范围需在 1–\(novel.chapters.count) 之间" }
        if b - a >= 200 { return "单次最多缓存 200 章" }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                storageOverviewCard

                if let novel {
                    batchDownloadCard(for: novel)
                }

                if running {
                    downloadProgressCard
                }

                if let message {
                    statusBanner(message)
                }

                if entries.isEmpty {
                    emptyStateCard
                } else {
                    cachedBooksSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .compatScrollDismissesKeyboardInteractively()
        .navigationTitle("离线章节")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .compatTopBarTrailing) {
                if novel == nil {
                    Button("清除所有", role: .destructive) { confirmingClearAll = true }
                        .disabled(entries.isEmpty || clearingAll || running)
                }
            }
        }
        .alert("清除所有离线章节？", isPresented: $confirmingClearAll) {
            Button("取消", role: .cancel) {}
            Button("清除所有", role: .destructive) { clearAll() }
        } message: {
            Text("将清除当前账号所有书籍的离线章节缓存。已下载的 EPUB、阅读进度和书签会保留，之后可以重新缓存章节。")
        }
        .task(id: account) { job?.cancel(); await reload() }
        .onDisappear { job?.cancel() }
        .confirmationDialog("清理本书离线章节？进度、书签和已下载文件会保留。", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("清理缓存", role: .destructive) {
                let id = confirmingDelete; confirmingDelete = nil
                Task { do { try await settings.offlineChapters.remove(account: account, bookID: id); await reload() } catch { message = error.localizedDescription; lastBatchHadFailures = true } }
            }
        }
    }

    // MARK: - 顶部存储概览卡片

    private var storageOverviewCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .frame(width: 36, height: 36)
                    .background(NoveliaStyle.brandGreen.opacity(0.13), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(novel?.title ?? "离线章节缓存")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(1)
                    Text("作用域：\(accountLabel)")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(16)

            Rectangle()
                .fill(NoveliaStyle.hairline)
                .frame(height: 0.75)
                .padding(.horizontal, 16)

            HStack(spacing: 0) {
                if let novel {
                    overviewMetric(value: "\(novel.chapters.count) 章", label: "全书章节")
                } else {
                    overviewMetric(value: "\(groups.count) 本", label: "缓存书籍")
                }
                overviewDivider
                overviewMetric(value: "\(entries.count) 章", label: "已缓存")
                overviewDivider
                overviewMetric(value: formattedTotalSize, label: "占用空间")
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 8)

            if let novel, !novel.chapters.isEmpty {
                let ratio = min(1.0, Double(entries.count) / Double(novel.chapters.count))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("本书离线覆盖率")
                            .font(NoveliaStyle.fontCaption)
                            .foregroundStyle(NoveliaStyle.muted)
                        Spacer()
                        Text("\(Int(round(ratio * 100)))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NoveliaStyle.hairline)
                            Capsule()
                                .fill(NoveliaStyle.brandGreen)
                                .frame(width: max(ratio > 0 ? 6 : 0, geo.size.width * ratio))
                        }
                    }
                    .frame(height: 5)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }

    private func overviewMetric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NoveliaStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(NoveliaStyle.fontCaption)
                .foregroundStyle(NoveliaStyle.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var overviewDivider: some View {
        Rectangle()
            .fill(NoveliaStyle.hairline)
            .frame(width: 0.75, height: 24)
    }

    // MARK: - 批量缓存控制卡（单书模式）

    private func batchDownloadCard(for novel: Novel) -> some View {
        let totalChapters = novel.chapters.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("批量缓存章节")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted)
                Spacer()
                if let range {
                    Text("已选 \(range.count) 章")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NoveliaStyle.brandGreen)
                }
            }
            .padding(.horizontal, 6)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    rangeInputBox(title: "起章", text: $first, field: .first)
                    Text("至")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NoveliaStyle.muted)
                    rangeInputBox(title: "末章", text: $last, field: .last)
                }

                if totalChapters > 0 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetChip(title: "前 20 章", start: 1, end: min(20, totalChapters))
                            if totalChapters > 20 {
                                presetChip(title: "前 50 章", start: 1, end: min(50, totalChapters))
                            }
                            if totalChapters > 50 {
                                presetChip(title: "前 100 章", start: 1, end: min(100, totalChapters))
                            }
                            if totalChapters > 50 {
                                presetChip(title: "最新 50 章", start: max(1, totalChapters - 49), end: totalChapters)
                            }
                            if totalChapters <= 200 {
                                presetChip(title: "全书（\(totalChapters)章）", start: 1, end: totalChapters)
                            }
                        }
                    }
                }

                if let rangeHint {
                    Label(rangeHint, systemImage: "exclamationmark.circle")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.warning)
                }

                Button {
                    focusedField = nil
                    download()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: running ? "hourglass" : "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("下载所选章节")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        (range == nil || running) ? NoveliaStyle.muted.opacity(0.35) : NoveliaStyle.brandGreen,
                        in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(range == nil || running)

                Text("每批最多 200 章。已缓存章节直接复用；清理后可重新下载最新正文。")
                    .font(NoveliaStyle.fontCaption)
                    .foregroundStyle(NoveliaStyle.muted)
            }
            .padding(16)
            .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
        }
    }

    private func rangeInputBox(title: String, text: Binding<String>, field: RangeField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(NoveliaStyle.fontMicro)
                .foregroundStyle(NoveliaStyle.muted)
            TextField(title, text: text)
                .keyboardType(.numberPad)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NoveliaStyle.ink)
                .focused($focusedField, equals: field)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous)
                .stroke(focusedField == field ? NoveliaStyle.brandGreen : NoveliaStyle.hairline, lineWidth: focusedField == field ? 1.5 : 0.75)
        )
    }

    private func presetChip(title: String, start: Int, end: Int) -> some View {
        let isActive = first == "\(start)" && last == "\(end)"
        return Button {
            NoveliaHaptics.selection()
            focusedField = nil
            first = "\(start)"
            last = "\(end)"
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? NoveliaStyle.brandGreen : NoveliaStyle.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isActive ? NoveliaStyle.brandGreen.opacity(0.13) : NoveliaStyle.paper,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(isActive ? NoveliaStyle.brandGreen.opacity(0.45) : NoveliaStyle.hairline, lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .disabled(running)
    }

    // MARK: - 下载进度与状态提示

    private var downloadProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("正在缓存章节…", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.ink)
                Spacer()
                Text("\(completed) / \(max(1, total))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NoveliaStyle.brandGreen)
            }
            ProgressView(value: Double(completed), total: Double(max(1, total)))
                .tint(NoveliaStyle.brandGreen)
            HStack {
                Spacer()
                Button("取消剩余下载", role: .destructive) { job?.cancel() }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(NoveliaStyle.danger.opacity(0.10), in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(NoveliaStyle.danger)
            }
        }
        .padding(16)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }

    private func statusBanner(_ text: String) -> some View {
        let tint = lastBatchHadFailures ? NoveliaStyle.warning : NoveliaStyle.brandGreen
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: lastBatchHadFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(NoveliaStyle.fontBody)
                .foregroundStyle(NoveliaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { message = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NoveliaStyle.muted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoveliaStyle.radiusMedium, style: .continuous)
                .stroke(tint.opacity(0.25), lineWidth: 0.75)
        )
    }

    // MARK: - 已缓存书籍列表与空状态

    private var cachedBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(novel == nil ? "已缓存书籍" : "已缓存内容")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.muted)
                Spacer()
                if novel == nil && sortedGroupIDs.count > 1 {
                    Text("按占用空间排序")
                        .font(NoveliaStyle.fontCaption)
                        .foregroundStyle(NoveliaStyle.muted.opacity(0.8))
                }
            }
            .padding(.horizontal, 6)

            ForEach(sortedGroupIDs, id: \.self) { id in
                let chapters = groups[id] ?? []
                cachedBookCard(id: id, chapters: chapters)
            }
        }
    }

    private func cachedBookCard(id: String, chapters: [OnlineChapterOfflineStore.Entry]) -> some View {
        let bytes = chapters.reduce(0) { $0 + $1.bytes }
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let share = totalBytes > 0 ? min(1.0, Double(bytes) / Double(totalBytes)) : 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
                    .frame(width: 34, height: 34)
                    .background(NoveliaStyle.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(chapters.first?.bookTitle ?? "缓存书籍")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NoveliaStyle.ink)
                        .lineLimit(2)
                    Text("\(chapters.count) 章 · \(sizeText)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NoveliaStyle.muted)
                }

                Spacer(minLength: 8)

                Button("清理本书缓存", role: .destructive) { confirmingDelete = id }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(NoveliaStyle.danger.opacity(0.10), in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(NoveliaStyle.danger)
            }

            if novel == nil && sortedGroupIDs.count > 1 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NoveliaStyle.hairline)
                        Capsule()
                            .fill(NoveliaStyle.brandGreen.opacity(0.75))
                            .frame(width: max(share > 0 ? 6 : 0, geo.size.width * share))
                    }
                }
                .frame(height: 4)
            }

            if novel != nil && !chapters.isEmpty {
                Rectangle()
                    .fill(NoveliaStyle.hairline)
                    .frame(height: 0.75)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandsChapterList.toggle()
                    }
                } label: {
                    HStack {
                        Text(expandsChapterList ? "收起已缓存章节" : "查看已缓存章节（\(chapters.count) 章）")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                        Spacer()
                        Image(systemName: expandsChapterList ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NoveliaStyle.brandGreen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expandsChapterList {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Text(entry.chapter.title)
                                    .font(NoveliaStyle.fontBody)
                                    .foregroundStyle(NoveliaStyle.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                                    .font(NoveliaStyle.fontCaption)
                                    .monospacedDigit()
                                    .foregroundStyle(NoveliaStyle.muted)
                            }
                            .padding(.vertical, 8)
                            if index < chapters.count - 1 {
                                Rectangle()
                                    .fill(NoveliaStyle.hairline)
                                    .frame(height: 0.75)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(NoveliaStyle.brandGreen.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: "tray")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(NoveliaStyle.brandGreen)
            }
            .accessibilityHidden(true)

            Text("暂无离线章节")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(NoveliaStyle.ink)

            Text("当前账号还没有离线章节。可在网络小说详情或阅读菜单中缓存章节。")
                .font(NoveliaStyle.fontBody)
                .foregroundStyle(NoveliaStyle.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .noveliaCard(cornerRadius: NoveliaStyle.radiusLarge)
    }

    // MARK: - 操作逻辑

    private func clearAll() {
        guard !clearingAll else { return }
        let owner = account
        clearingAll = true
        Task {
            defer { clearingAll = false }
            do {
                try await settings.offlineChapters.remove(account: owner)
                guard owner == account else { return }
                await reload()
                lastBatchHadFailures = false
                message = "已清除当前账号的所有离线章节。"
            } catch {
                guard owner == account else { return }
                await reload()
                lastBatchHadFailures = true
                message = error.localizedDescription
            }
        }
    }

    private func reload() async {
        do { entries = try await settings.offlineChapters.entries(account: account).filter { novel == nil || $0.bookID == novel?.id } }
        catch {
            lastBatchHadFailures = true
            message = error.localizedDescription
        }
    }

    private func download() {
        guard let novel, let range else { return }
        let owner = account
        running = true; completed = 0; total = range.count; message = nil; lastBatchHadFailures = false
        job = Task {
            defer { running = false; job = nil }
            var failed = 0
            for index in range {
                if Task.isCancelled || account != owner { break }
                do { _ = try await settings.offlineChapters.chapter(novel.chapters[index], book: novel, account: owner, service: services.api.content) }
                catch is CancellationError { break }
                catch { failed += 1; message = error.localizedDescription }
                completed += 1
            }
            await reload()
            lastBatchHadFailures = failed > 0
            message = "已处理\(completed)/\(total)章，失败\(failed)章。" + (message.map { " \($0)" } ?? "")
        }
    }
}

extension AccountAuthStore {
    var offlineAccountScope: String { username.map { "account:" + $0 } ?? "anonymous" }
}
