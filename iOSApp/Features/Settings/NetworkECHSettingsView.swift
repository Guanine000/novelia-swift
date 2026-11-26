import SwiftUI

/// Novelia 原站 ECH（加密 SNI）开关、自定义 DoH 节点与连接诊断页。
struct NetworkECHSettingsView: View {
    @AppStorage(SettingsKey.networkECHEnabled) private var echEnabled = false
    @State private var customDoHDraft: String = NoveliaECHController.shared.customDoHRaw
    @State private var dohFeedback: String?
    @State private var dohFeedbackIsError = false
    @State private var isProbing = false
    @State private var probeReports: [ECHProbeReport] = []
    @State private var recentRecords: [ECHRequestDiagnosticRecord] = NoveliaECHController.shared.recentDiagnostics
    @State private var resetNotice: String?

    private static let dohPresets: [(title: String, value: String)] = [
        ("内置默认", ""),
        ("阿里 DNS", "https://dns.alidns.com/dns-query\nhttps://223.5.5.5/dns-query"),
        ("Cloudflare", "https://1.1.1.1/dns-query\nhttps://cloudflare-dns.com/dns-query"),
        ("Google", "https://8.8.8.8/dns-query")
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $echEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 ECH（加密 SNI）")
                        Text("使用内置 DoH 与 TLS 1.3 ECH 连接 Novelia 原站。握手失败时不静默降级为明文 SNI。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("仅对 n.novelia.cc、auth.novelia.cc 与 forum.novelia.cc（HTTPS 443）生效；WebDAV、外部图床、更新检查与 AI 服务不受影响。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每行填写一个 https:// DoH 地址（最多 8 个），留空则使用内置默认节点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $customDoHDraft)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 76)
                        .padding(6)
                        .background(NoveliaStyle.paper, in: RoundedRectangle(cornerRadius: NoveliaStyle.radiusSmall))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.dohPresets, id: \.title) { preset in
                                Button(preset.title) {
                                    customDoHDraft = preset.value
                                    applyDoH(preset.value)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Button("保存并应用 DoH 节点") {
                    applyDoH(customDoHDraft)
                }

                if let dohFeedback {
                    Text(dohFeedback)
                        .font(.caption)
                        .foregroundStyle(dohFeedbackIsError ? NoveliaStyle.danger : NoveliaStyle.brandGreen)
                }
            } header: {
                Text("DoH 解析节点")
            } footer: {
                Text("内置默认节点：\(NoveliaECHController.defaultDoHDescription)。")
            }

            Section {
                Button {
                    runDiagnostics()
                } label: {
                    HStack(spacing: 8) {
                        if isProbing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(isProbing ? "正在诊断…" : "运行 ECH 连接诊断")
                    }
                }
                .disabled(isProbing)

                ForEach(probeReports) { report in
                    DisclosureGroup {
                        ECHEventTimelineView(events: report.events)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: report.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.ok ? NoveliaStyle.brandGreen : NoveliaStyle.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(report.host)
                                        .font(.subheadline.monospaced())
                                    Spacer()
                                    if report.elapsedMs > 0 {
                                        Text("\(report.elapsedMs) ms")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(report.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Button("重置连接池与 DNS 缓存") {
                    NoveliaECHController.shared.resetNetworkState()
                    resetNotice = "已重置 ECH 连接池与解析缓存。"
                }
                .disabled(isProbing)
            } header: {
                Text("连接诊断")
            } footer: {
                if let resetNotice {
                    Text(resetNotice)
                } else {
                    Text("诊断仅发起匿名 TLS 1.3 / ECH 握手测试，展开各域名可查看 DoH、代理、TCP 与 TLS 阶段耗时；脱敏诊断同时写入“导出应用日志”。")
                }
            }

            Section {
                if recentRecords.isEmpty {
                    Text("暂无 ECH 请求记录。开启 ECH 并发起浏览或登录后，可在此查看最近 30 条请求的阶段明细。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentRecords) { record in
                        DisclosureGroup {
                            ECHEventTimelineView(events: record.events)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: record.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(record.outcome == "ok" ? NoveliaStyle.brandGreen : NoveliaStyle.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(record.method) \(record.host)")
                                            .font(.caption.monospaced())
                                        Spacer()
                                        Text("\(record.elapsedMs) ms")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(recordSummary(record))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("刷新明细") {
                        recentRecords = NoveliaECHController.shared.recentDiagnostics
                    }
                    Spacer()
                    if !recentRecords.isEmpty {
                        Button("清空", role: .destructive) {
                            NoveliaECHController.shared.clearRecentDiagnostics()
                            recentRecords = []
                        }
                    }
                }
            } header: {
                Text("最近 ECH 请求明细")
            }
        }
        .compatScrollContentBackgroundHidden()
        .background(NoveliaStyle.paper.ignoresSafeArea())
        .navigationTitle("加密连接（ECH）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customDoHDraft = NoveliaECHController.shared.customDoHRaw
            recentRecords = NoveliaECHController.shared.recentDiagnostics
        }
    }

    private func applyDoH(_ value: String) {
        if let error = NoveliaECHController.shared.applyCustomDoH(value) {
            dohFeedback = error
            dohFeedbackIsError = true
        } else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            customDoHDraft = trimmed
            dohFeedback = trimmed.isEmpty ? "已恢复使用内置默认 DoH 节点。" : "已保存自定义 DoH 节点并重置解析缓存。"
            dohFeedbackIsError = false
        }
    }

    private func runDiagnostics() {
        guard !isProbing else { return }
        isProbing = true
        resetNotice = nil
        probeReports = NoveliaECHController.protectedHosts.map {
            ECHProbeReport(host: $0, ok: false, summary: "检测中…", elapsedMs: 0, events: [])
        }
        Task {
            var collected: [ECHProbeReport] = []
            for host in NoveliaECHController.protectedHosts {
                let report = await NoveliaECHController.shared.probeDiagnostics(host: host)
                collected.append(report)
                let pending = NoveliaECHController.protectedHosts.dropFirst(collected.count).map {
                    ECHProbeReport(host: $0, ok: false, summary: "等待中…", elapsedMs: 0, events: [])
                }
                probeReports = collected + pending
            }
            probeReports = collected
            recentRecords = NoveliaECHController.shared.recentDiagnostics
            isProbing = false
        }
    }

    private func recordSummary(_ record: ECHRequestDiagnosticRecord) -> String {
        let time = Self.timeFormatter.string(from: record.timestamp)
        if let status = record.statusCode {
            return "\(time) · HTTP \(status)"
        }
        if let label = record.failureLabel {
            return "\(time) · \(label)"
        }
        return "\(time) · \(record.outcome)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

private struct ECHEventTimelineView: View {
    let events: [ECHDiagnosticEvent]

    var body: some View {
        if events.isEmpty {
            Text("暂无阶段事件")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("+\(event.atMillis)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.stageDisplayName) · \(event.outcome)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(event.outcome == "failed" ? NoveliaStyle.danger : NoveliaStyle.ink)
                            let detail = eventDetail(event)
                            if !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func eventDetail(_ event: ECHDiagnosticEvent) -> String {
        var parts: [String] = []
        if let duration = event.durationMs, duration > 0 { parts.append("\(duration)ms") }
        if let resolver = event.resolver, !resolver.isEmpty { parts.append("doh=\(resolver)") }
        if let family = event.family, !family.isEmpty { parts.append(family) }
        if let ip = event.serverIp, !ip.isEmpty { parts.append("ip=\(ip)") }
        if let proto = event.protocolName, !proto.isEmpty { parts.append(proto) }
        if let reason = event.reason, !reason.isEmpty { parts.append("reason=\(reason)") }
        return parts.joined(separator: " · ")
    }
}
