// SPDX-License-Identifier: GPL-3.0-only
import CFNetwork
import Foundation
import Network
import UIKit
#if canImport(NoveliaECH)
import NoveliaECH
#endif

/// Go 侧单步隐私安全诊断事件（不含 URL、请求头、凭据或原始错误文本）。
struct ECHDiagnosticEvent: Codable, Identifiable, Sendable {
    var id: String { "\(stage)-\(outcome)-\(atMillis)-\(attempt ?? 0)-\(resolver ?? "")" }
    let stage: String
    let outcome: String
    let atMillis: Int64
    let durationMs: Int64?
    let reason: String?
    let resolver: String?
    let family: String?
    let serverIp: String?
    let attempt: Int?
    let protocolName: String?

    enum CodingKeys: String, CodingKey {
        case stage, outcome, atMillis, durationMs, reason, resolver, family, serverIp, attempt
        case protocolName = "protocol"
    }

    var stageDisplayName: String {
        switch stage {
        case "doh_ech": "DoH / ECH 解析"
        case "doh_provider": "DoH 节点"
        case "proxy": "系统代理选路"
        case "connect_attempt": "建连尝试"
        case "tcp": "TCP 连接"
        case "tls": "TLS / ECH 握手"
        case "ech": "ECH 校验"
        case "response_headers": "响应头"
        case "body": "正文读取"
        default: stage
        }
    }
}

struct ECHProbeReport: Codable, Identifiable, Sendable {
    var id: String { host }
    let host: String
    let ok: Bool
    let summary: String
    let elapsedMs: Int64
    let events: [ECHDiagnosticEvent]
}

struct ECHRequestDiagnosticRecord: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let method: String
    let statusCode: Int?
    let outcome: String
    let failureLabel: String?
    let elapsedMs: Int
    let events: [ECHDiagnosticEvent]
}

/// Novelia 原站 ECH（Encrypted Client Hello）传输控制器。
/// 职责：持有单一 Go `EchClient` 实例、管理自定义 DoH 节点、桥接 iOS 系统代理、
/// 监听网络路径变化与前后台切换、记录隐私安全诊断明细，并提供仅拦截受保护域名
/// （`n/auth/forum.novelia.cc`）的 `URLSession`。
/// WebDAV、公开更新检查、Edge TTS 与 AI 客户端不经过本通道。
final class NoveliaECHController: @unchecked Sendable {
    static let shared = NoveliaECHController()

    static let protectedHosts: [String] = [
        "n.novelia.cc",
        "auth.novelia.cc",
        "forum.novelia.cc"
    ]

    static let defaultDoHDescription = "阿里 DNS（dns.alidns.com / 223.5.5.5）、Cloudflare（1.1.1.1 / cloudflare-dns.com）、Google（8.8.8.8 / dns.google）"

    private static let protectedHostSet = Set(protectedHosts)
    private static let maxRecentRecords = 30

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "cc.novelia.ech.network-monitor")
    private var lastPathSignature: String?
    private var foregroundObserver: NSObjectProtocol?
    private var recentRecords: [ECHRequestDiagnosticRecord] = []
    #if canImport(NoveliaECH)
    private var nativeClient: EchClient?
    #endif

    /// 供小说 API、论坛 API、原生登录/续期与站内图片共用的 URLSession；
    /// 关闭 ECH 时 `NoveliaECHURLProtocol.canInit` 直接返回 false，零开销回落标准传输。
    lazy var session: URLSession = makeURLSession(baseConfiguration: .default)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startNetworkMonitoring()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: SettingsKey.networkECHEnabled)
    }

    var customDoHRaw: String {
        defaults.string(forKey: SettingsKey.networkECHCustomDoH) ?? ""
    }

    var hasCustomDoH: Bool {
        !customDoHRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var recentDiagnostics: [ECHRequestDiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recentRecords
    }

    func clearRecentDiagnostics() {
        lock.lock()
        recentRecords.removeAll()
        lock.unlock()
    }

    func shouldIntercept(_ request: URLRequest) -> Bool {
        guard isEnabled,
              let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              (url.port == nil || url.port == 443),
              let host = url.host?.lowercased(),
              Self.protectedHostSet.contains(host) else {
            return false
        }
        return true
    }

    func makeURLSession(baseConfiguration: URLSessionConfiguration = .default) -> URLSession {
        let config = (baseConfiguration.copy() as? URLSessionConfiguration) ?? .default
        var protocols = config.protocolClasses ?? []
        if !protocols.contains(where: { $0 == NoveliaECHURLProtocol.self }) {
            protocols.insert(NoveliaECHURLProtocol.self, at: 0)
        }
        config.protocolClasses = protocols
        return URLSession(configuration: config)
    }

    /// 校验并应用自定义 DoH 节点列表；传入空字符串恢复内置默认节点。返回 nil 表示成功，否则返回错误说明。
    func applyCustomDoH(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(NoveliaECH)
        guard let echClient = client() else { return "ECH 引擎未就绪" }
        do {
            try echClient.setCustomDoHResolvers(trimmed)
            defaults.set(trimmed, forKey: SettingsKey.networkECHCustomDoH)
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        defaults.set(trimmed, forKey: SettingsKey.networkECHCustomDoH)
        return nil
        #endif
    }

    #if canImport(NoveliaECH)
    fileprivate func client() -> EchClient? {
        lock.lock()
        defer { lock.unlock() }
        if let nativeClient { return nativeClient }
        let created = EchNewClientWithProxyResolver(IOSSystemECHProxyResolver())
        let savedDoH = defaults.string(forKey: SettingsKey.networkECHCustomDoH)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !savedDoH.isEmpty {
            try? created?.setCustomDoHResolvers(savedDoH)
        }
        nativeClient = created
        return created
    }
    #endif

    func resetNetworkState() {
        #if canImport(NoveliaECH)
        lock.lock()
        let current = nativeClient
        lock.unlock()
        current?.resetNetworkState()
        #endif
    }

    func probe(host: String) async -> String {
        await probeDiagnostics(host: host).summary
    }

    func probeDiagnostics(host: String) async -> ECHProbeReport {
        #if canImport(NoveliaECH)
        let report: ECHProbeReport = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let client = self.client() else {
                    continuation.resume(returning: ECHProbeReport(host: host, ok: false, summary: "ECH 引擎未就绪", elapsedMs: 0, events: []))
                    return
                }
                let raw = client.probeDiagnostics(host)
                if let data = raw.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(ECHProbeReport.self, from: data) {
                    continuation.resume(returning: decoded)
                } else {
                    continuation.resume(returning: ECHProbeReport(host: host, ok: false, summary: "诊断结果解析失败", elapsedMs: 0, events: []))
                }
            }
        }
        logProbeDiagnostic(report)
        return report
        #else
        return ECHProbeReport(host: host, ok: false, summary: "当前构建未包含 ECH 原生库", elapsedMs: 0, events: [])
        #endif
    }

    fileprivate func recordRequestDiagnostic(host: String, method: String, statusCode: Int?, outcome: String,
                                             failureLabel: String?, elapsedMs: Int, diagnosticsJSON: String) {
        let events = Self.decodeDiagnosticEvents(diagnosticsJSON)
        let record = ECHRequestDiagnosticRecord(
            timestamp: Date(),
            host: host,
            method: method,
            statusCode: statusCode,
            outcome: outcome,
            failureLabel: failureLabel,
            elapsedMs: elapsedMs,
            events: events
        )
        lock.lock()
        recentRecords.insert(record, at: 0)
        if recentRecords.count > Self.maxRecentRecords {
            recentRecords.removeLast(recentRecords.count - Self.maxRecentRecords)
        }
        lock.unlock()

        let summary = Self.summarizeEvents(events)
        let message = AppDiagnosticMessage.echRequest(
            host: Self.hostLogLabel(host),
            outcome: outcome,
            status: statusCode ?? -1,
            stage: summary.stage,
            reason: summary.reason,
            resolver: summary.resolver,
            family: summary.family,
            customDoH: hasCustomDoH,
            elapsedMs: elapsedMs
        )
        let logger = ShareableLogger(category: "ech")
        if outcome == "failed" {
            logger.error(message)
        } else {
            logger.notice(message)
        }
    }

    private func logProbeDiagnostic(_ report: ECHProbeReport) {
        let summary = Self.summarizeEvents(report.events)
        let message = AppDiagnosticMessage.echProbe(
            host: Self.hostLogLabel(report.host),
            ok: report.ok,
            stage: summary.stage,
            reason: summary.reason,
            resolver: summary.resolver,
            family: summary.family,
            customDoH: hasCustomDoH,
            elapsedMs: Int(report.elapsedMs)
        )
        let logger = ShareableLogger(category: "ech")
        if report.ok {
            logger.notice(message)
        } else {
            logger.error(message)
        }
    }

    static func decodeDiagnosticEvents(_ json: String) -> [ECHDiagnosticEvent] {
        guard let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode([ECHDiagnosticEvent].self, from: data) else {
            return []
        }
        return events
    }

    private static func hostLogLabel(_ host: String) -> String {
        switch host.lowercased() {
        case "n.novelia.cc": "novel"
        case "auth.novelia.cc": "auth"
        case "forum.novelia.cc": "forum"
        default: "other"
        }
    }

    private static func summarizeEvents(_ events: [ECHDiagnosticEvent]) -> (stage: String, reason: String, resolver: String, family: String) {
        let failed = events.last(where: { $0.outcome == "failed" })
        let stage = failed?.stage ?? events.last?.stage ?? "none"
        let reason = failed?.reason ?? "none"
        let resolver = events.last(where: { ($0.resolver?.isEmpty == false) })?.resolver ?? "none"
        let family = events.last(where: { ($0.family?.isEmpty == false) })?.family ?? "none"
        return (stage, reason, resolver, family)
    }

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            let signature = "\(path.status)|\(interfaces)|\(path.isExpensive)|\(path.isConstrained)"
            self.lock.lock()
            let previous = self.lastPathSignature
            self.lastPathSignature = signature
            self.lock.unlock()
            if previous != nil && previous != signature {
                self.resetNetworkState()
            }
        }
        monitor.start(queue: monitorQueue)

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resetNetworkState()
        }
    }
}

#if canImport(NoveliaECH)
/// 将 iOS 系统代理设置（Wi-Fi HTTP 代理 / 绕过规则）提供给 Go ECH 引擎；
/// 返回空字符串表示明确直连，不支持的代理类型报错而不是静默绕过代理。
private final class IOSSystemECHProxyResolver: NSObject, EchProxyResolverProtocol {
    func resolveProxy(_ rawURL: String?, error: NSErrorPointer) -> String {
        guard let rawURL, let url = URL(string: rawURL) else {
            return ""
        }
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            return ""
        }
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as NSArray
        for item in proxies {
            guard let dict = item as? [String: Any],
                  let type = dict[kCFProxyTypeKey as String] as? String else { continue }
            if type == (kCFProxyTypeNone as String) {
                return ""
            }
            if type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String) {
                guard let host = dict[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
                      let portNumber = dict[kCFProxyPortNumberKey as String] as? NSNumber else {
                    error?.pointee = NSError(domain: "NoveliaECHProxy", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "invalid system proxy"])
                    return ""
                }
                let port = portNumber.intValue
                guard (1...65535).contains(port) else {
                    error?.pointee = NSError(domain: "NoveliaECHProxy", code: 2,
                                             userInfo: [NSLocalizedDescriptionKey: "invalid system proxy port"])
                    return ""
                }
                let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                return "http://\(formattedHost):\(port)"
            }
            // PAC / SOCKS 暂不支持在 Go HTTP CONNECT 层直接解析，明确报错而不静默绕过。
            error?.pointee = NSError(domain: "NoveliaECHProxy", code: 3,
                                     userInfo: [NSLocalizedDescriptionKey: "unsupported system proxy"])
            return ""
        }
        return ""
    }
}

private final class MemoryECHUpload: NSObject, EchUploadProtocol {
    private let data: Data
    private var offset = 0
    private let lock = NSLock()

    init(data: Data) {
        self.data = data
    }

    func readChunk(_ maxBytes: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset < data.count, maxBytes > 0 else { return Data() }
        let count = min(maxBytes, min(65536, data.count - offset))
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    func close() {
        lock.lock()
        offset = data.count
        lock.unlock()
    }
}

private final class StreamECHUpload: NSObject, EchUploadProtocol {
    private let stream: InputStream
    private var opened = false
    private var closed = false
    private let lock = NSLock()

    init(stream: InputStream) {
        self.stream = stream
    }

    func readChunk(_ maxBytes: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, maxBytes > 0 else { return Data() }
        if !opened {
            stream.open()
            opened = true
        }
        let capacity = min(maxBytes, 65536)
        var buffer = [UInt8](repeating: 0, count: capacity)
        let readCount = stream.read(&buffer, maxLength: capacity)
        if readCount > 0 {
            return Data(buffer[0..<readCount])
        }
        if readCount == 0 {
            return Data()
        }
        throw stream.streamError
            ?? NSError(domain: "NoveliaECHUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "upload stream read failed"])
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            if opened { stream.close() }
        }
    }
}
#endif

/// 拦截受保护域名请求的 URLProtocol，将请求流式转交 Go ECH 引擎；
/// 严格要求 TLS 1.3 + ECH 协商通过，失败不降级到明文 SNI，并采集隐私安全诊断明细。
final class NoveliaECHURLProtocol: URLProtocol {
    private static let workQueue = DispatchQueue(label: "cc.novelia.ech.transport", qos: .userInitiated, attributes: .concurrent)

    private static let safeReasons: Set<String> = [
        "连接失败", "连接超时", "请求发送超时", "响应读取超时", "连接被中断",
        "证书验证未通过", "服务器拒绝 ECH 配置", "TLS 协商未完成",
        "系统代理需要认证", "系统代理配置不受支持", "系统代理连接失败"
    ]

    private let stateLock = NSLock()
    private var isCancelled = false
    #if canImport(NoveliaECH)
    private var activeCall: EchCall?
    private var activeUpload: (any EchUploadProtocol)?
    #endif

    override class func canInit(with request: URLRequest) -> Bool {
        NoveliaECHController.shared.shouldIntercept(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        #if canImport(NoveliaECH)
        Self.workQueue.async { [weak self] in
            self?.runRequest()
        }
        #else
        client?.urlProtocol(self, didFailWithError: makeError(reason: "连接失败"))
        #endif
    }

    override func stopLoading() {
        stateLock.lock()
        isCancelled = true
        #if canImport(NoveliaECH)
        let call = activeCall
        let upload = activeUpload
        activeCall = nil
        activeUpload = nil
        #endif
        stateLock.unlock()
        #if canImport(NoveliaECH)
        call?.cancel()
        upload?.close()
        #endif
    }

    private func cancelled() -> Bool {
        stateLock.lock()
        let value = isCancelled
        stateLock.unlock()
        return value
    }

    #if canImport(NoveliaECH)
    private func runRequest() {
        guard !cancelled() else { return }
        guard let url = request.url, let echClient = NoveliaECHController.shared.client() else {
            deliverFailure(reason: "连接失败")
            return
        }

        let startedAt = MonotonicInstant.now
        let host = url.host?.lowercased() ?? "unknown"
        let method = request.httpMethod ?? "GET"
        var headerMap: [String: [String]] = [:]
        if let fields = request.allHTTPHeaderFields {
            for (name, value) in fields {
                let lower = name.lowercased()
                if lower == "host" || lower == "connection" || lower == "content-length" { continue }
                headerMap[name] = [value]
            }
        }
        guard let headersData = try? JSONSerialization.data(withJSONObject: headerMap),
              let headersJSON = String(data: headersData, encoding: .utf8) else {
            deliverFailure(reason: "连接失败")
            return
        }

        let upload: (any EchUploadProtocol)?
        let contentLength: Int64
        if let body = request.httpBody, !body.isEmpty {
            upload = MemoryECHUpload(data: body)
            contentLength = Int64(body.count)
        } else if let stream = request.httpBodyStream {
            upload = StreamECHUpload(stream: stream)
            contentLength = -1
        } else {
            upload = nil
            contentLength = 0
        }

        let timeoutMillis = Int64(max(15, min(request.timeoutInterval > 0 ? request.timeoutInterval : 30, 600)) * 1000)
        let connectTimeoutMillis: Int64 = min(20_000, timeoutMillis)

        let call: EchCall
        do {
            call = try echClient.newCall(
                method,
                rawURL: url.absoluteString,
                headersJSON: headersJSON,
                upload: upload,
                contentLength: contentLength,
                connectTimeoutMillis: connectTimeoutMillis,
                readTimeoutMillis: timeoutMillis,
                writeTimeoutMillis: timeoutMillis
            )
        } catch {
            upload?.close()
            deliverFailure(reason: "连接失败")
            return
        }
        call.enableDiagnostics()

        stateLock.lock()
        if isCancelled {
            stateLock.unlock()
            call.cancel()
            upload?.close()
            return
        }
        activeCall = call
        activeUpload = upload
        stateLock.unlock()

        var finalOutcome = "cancelled"
        var finalStatus: Int?
        var finalFailureLabel: String?

        defer {
            let diagnosticsJSON = call.diagnosticsJSON()
            let elapsedMs = DiagnosticContext.milliseconds(since: startedAt)
            stateLock.lock()
            activeCall = nil
            activeUpload = nil
            stateLock.unlock()
            call.cancel()
            upload?.close()
            NoveliaECHController.shared.recordRequestDiagnostic(
                host: host,
                method: method,
                statusCode: finalStatus,
                outcome: finalOutcome,
                failureLabel: finalFailureLabel,
                elapsedMs: elapsedMs,
                diagnosticsJSON: diagnosticsJSON
            )
        }

        let reply: EchReply
        do {
            reply = try call.execute()
        } catch {
            if !cancelled() {
                let reason = call.failureReason()
                finalOutcome = "failed"
                finalFailureLabel = Self.safeReasons.contains(reason) ? reason : "连接失败"
                deliverFailure(reason: reason)
            }
            return
        }

        guard !cancelled() else { return }

        let responseHeaders = Self.decodeHeaders(reply.headersJSON())
        let statusCode = reply.statusCode()
        finalStatus = statusCode
        let httpVersion = reply.protocol().isEmpty ? "HTTP/1.1" : reply.protocol()
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: httpVersion,
            headerFields: responseHeaders
        ) else {
            finalOutcome = "failed"
            finalFailureLabel = "连接失败"
            deliverFailure(reason: "连接失败")
            return
        }

        // 重定向交给 URLSession 委托统一处理，外部域名自动退出 ECH 白名单并按原策略剥离跨源凭据。
        if [301, 302, 303, 307, 308].contains(statusCode),
           let location = responseHeaders.first(where: { $0.key.caseInsensitiveCompare("Location") == .orderedSame })?.value,
           let nextURL = URL(string: location, relativeTo: url)?.absoluteURL {
            var redirected = request
            redirected.url = nextURL
            if statusCode == 303 || ((statusCode == 301 || statusCode == 302) && method == "POST") {
                redirected.httpMethod = "GET"
                redirected.httpBody = nil
                redirected.httpBodyStream = nil
            }
            if nextURL.host?.lowercased() != url.host?.lowercased() || nextURL.scheme?.lowercased() != url.scheme?.lowercased() {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            finalOutcome = "ok"
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: httpResponse)
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        while !cancelled() {
            do {
                let chunk = try call.read(65536)
                if chunk.isEmpty {
                    if !cancelled() {
                        finalOutcome = "ok"
                        client?.urlProtocolDidFinishLoading(self)
                    }
                    return
                }
                if !cancelled() {
                    client?.urlProtocol(self, didLoad: chunk)
                }
            } catch {
                if !cancelled() {
                    let reason = call.failureReason()
                    finalOutcome = "failed"
                    finalFailureLabel = Self.safeReasons.contains(reason) ? reason : "响应读取失败"
                    deliverFailure(reason: reason, fallback: "响应读取失败")
                }
                return
            }
        }
    }

    private static func decodeHeaders(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (name, values) in raw {
            let lower = name.lowercased()
            if lower == "connection" || lower == "transfer-encoding" { continue }
            let clean = values.filter { value in
                value.unicodeScalars.allSatisfy { $0.value == 0x09 || ($0.value >= 0x20 && $0.value != 0x7f) }
            }
            guard !clean.isEmpty else { continue }
            result[name] = clean.joined(separator: ", ")
        }
        return result
    }
    #endif

    private func deliverFailure(reason: String, fallback: String = "连接失败") {
        client?.urlProtocol(self, didFailWithError: makeError(reason: reason, fallback: fallback))
    }

    private func makeError(reason: String, fallback: String = "连接失败") -> NSError {
        let label = Self.safeReasons.contains(reason) ? reason : fallback
        return NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSLocalizedDescriptionKey: "ECH \(label)，请在设置中运行连接诊断。"]
        )
    }
}
