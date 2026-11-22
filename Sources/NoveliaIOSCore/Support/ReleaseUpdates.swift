import Combine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // Linux 把 URLSession 放在这个模块；Apple 仍由 Foundation 提供。
#endif

// GitHub release check offered at launch (see "我的 → 版本").

/// 发布标签与本机版本号。兼容常见写法：
/// - 前缀：`v`、`V`，以及由字母、`-`、`_` 组成的前缀（如 `release-`、`Novelia-v`）；
/// - 1–4 段数字，缺少的段按 0 比较（`0.20` 与 `0.20.0` 相同）；
/// - SemVer 预发布后缀 `-test.2`：低于同号正式版，按 SemVer 规则比较；
/// - 构建元数据 `+34`：不参与比较。
/// 数字段含非数字（如 `0.x.0`）或出现其他字符时无效。
struct NoveliaReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    /// 预发布标识，按 `.` 分段；正式版为空。
    let prerelease: [String]

    init?(_ text: String) {
        var value = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let firstDigit = value.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        let prefix = value[..<firstDigit]
        guard prefix.count <= 24, prefix.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "-" || $0 == "_" }) else { return nil }
        value = value[firstDigit...]
        if let plus = value.firstIndex(of: "+") {
            let build = value[value.index(after: plus)...]
            guard Self.isValidIdentifierList(build) else { return nil }
            value = value[..<plus]
        }
        var pre: [String] = []
        if let dash = value.firstIndex(of: "-") {
            let tail = value[value.index(after: dash)...]
            guard Self.isValidIdentifierList(tail) else { return nil }
            pre = tail.split(separator: ".").map(String.init)
            value = value[..<dash]
        }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count),
              fields.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        parts = fields.map { Int($0)! }
        prerelease = pre
    }

    private static func isValidIdentifierList(_ text: Substring) -> Bool {
        let ids = text.split(separator: ".", omittingEmptySubsequences: false)
        return !ids.isEmpty && ids.allSatisfy { id in
            !id.isEmpty && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// 至少显示三段，如 `0.20.0`、`0.20.0-test.2`。可再次解析为相等的版本，用于保存“忽略此版本”。
    var display: String {
        let numbers = (parts + Array(repeating: 0, count: max(0, 3 - parts.count))).map(String.init).joined(separator: ".")
        return isPrerelease ? numbers + "-" + prerelease.joined(separator: ".") : numbers
    }

    private var paddedParts: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.paddedParts == rhs.paddedParts && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.paddedParts != rhs.paddedParts { return lhs.paddedParts.lexicographicallyPrecedes(rhs.paddedParts) }
        // 同号时：有预发布标识的版本较低；都有时逐段比较（数字段按数值、数字段低于字母段，前缀相同时段少者较低）。
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, _): return false
        case (true, false): return true
        case (true, true):
            for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
                switch (Int(a), Int(b)) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a < b
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}

/// 从 GitHub Release 正文提取更新提示用的短说明。
/// 只取开场段落：跳过开头的空行、ATX 标题和分隔线，再整理成纯文本。
/// 在本地完成，不请求网络，也不调用摘要模型。缺失、空白或只剩标题时返回 nil。
enum NoveliaReleaseNotes {
    /// 提示中摘要的字数上限，按扩展字形簇计算。超出改为省略号，全文仍在 GitHub。
    static let summaryCharacterLimit = 160

    static func openingSummary(_ body: String?) -> String? {
        guard var text = body else { return nil }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count, isSkippableLead(lines[index]) { index += 1 }
        var paragraph: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isATXHeading(trimmed) { break }
            paragraph.append(strippedBlockMarkers(trimmed))
            index += 1
        }
        let plain = plainText(paragraph.joined(separator: " "))
        guard !plain.isEmpty else { return nil }
        return bounded(plain)
    }

    private static func isSkippableLead(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || isATXHeading(trimmed) || isThematicBreak(trimmed)
    }

    private static func isATXHeading(_ line: String) -> Bool {
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard (1...6).contains(count) else { return false }
        if count == line.count { return true }
        let next = line[line.index(line.startIndex, offsetBy: count)]
        return next == " " || next == "\t"
    }

    /// 分隔线不是说明文字。只跳过开头的分隔线，避免把 `---` 当成摘要。
    private static func isThematicBreak(_ line: String) -> Bool {
        guard let marker = line.first, marker == "-" || marker == "*" || marker == "_" else { return false }
        var count = 0
        for character in line {
            if character == marker { count += 1 }
            else if character == " " || character == "\t" { continue }
            else { return false }
        }
        return count >= 3
    }

    private static func strippedBlockMarkers(_ line: String) -> String {
        var text = line
        var changed = true
        while changed {
            changed = false
            if text.first == ">" {
                text = String(text.dropFirst())
                if text.first == " " || text.first == "\t" { text = String(text.dropFirst()) }
                text = text.trimmingCharacters(in: .whitespaces)
                changed = true
                continue
            }
            if let rest = strippingListMarker(text) {
                text = rest
                changed = true
            }
        }
        return text
    }

    private static func strippingListMarker(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = text.dropFirst()
            guard let space = rest.first, space == " " || space == "\t" else { return nil }
            return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
        }
        var index = text.startIndex
        var digits = 0
        while index < text.endIndex, text[index].isNumber, digits < 9 {
            digits += 1
            index = text.index(after: index)
        }
        guard digits > 0, index < text.endIndex, text[index] == "." || text[index] == ")" else { return nil }
        let markerEnd = text.index(after: index)
        guard markerEnd < text.endIndex, text[markerEnd] == " " || text[markerEnd] == "\t" else { return nil }
        return String(text[markerEnd...].drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func plainText(_ markdown: String) -> String {
        var result = ""
        var index = markdown.startIndex
        while index < markdown.endIndex {
            if let escaped = unescaped(markdown, at: index) {
                result.append(escaped.character)
                index = escaped.end
                continue
            }
            if let link = consumingLink(markdown, at: index) {
                result.append(contentsOf: plainText(link.label))
                index = link.end
                continue
            }
            if let code = consumingCodeSpan(markdown, at: index) {
                result.append(contentsOf: code.text)
                index = code.end
                continue
            }
            if let autolink = consumingAutolink(markdown, at: index) {
                result.append(contentsOf: autolink.value)
                index = autolink.end
                continue
            }
            let character = markdown[index]
            if character == "*" || character == "_" {
                let length = runLength(markdown, from: index, matching: character)
                if shouldOmitDelimiter(markdown, at: index, character: character, length: length) {
                    index = markdown.index(index, offsetBy: length)
                    continue
                }
            }
            result.append(character)
            index = markdown.index(after: index)
        }
        return collapseWhitespace(result)
    }

    private static func unescaped(_ text: String, at index: String.Index) -> (character: Character, end: String.Index)? {
        guard text[index] == "\\" else { return nil }
        let next = text.index(after: index)
        guard next < text.endIndex else { return nil }
        let character = text[next]
        guard "\\*_[]()`#!<>.".contains(character) else { return nil }
        return (character, text.index(after: next))
    }

    /// 行内链接和图片只保留可读文字，不把地址放进提示。
    private static func consumingLink(_ text: String, at start: String.Index) -> (label: String, end: String.Index)? {
        var marker = start
        if text[marker] == "!" {
            let next = text.index(after: marker)
            guard next < text.endIndex, text[next] == "[" else { return nil }
            marker = next
        }
        guard text[marker] == "[" else { return nil }
        let labelStart = text.index(after: marker)
        guard let labelEnd = closingBracket(text, from: labelStart) else { return nil }
        let label = String(text[labelStart..<labelEnd])
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex else { return nil }
        if text[afterLabel] == "(" {
            let destinationStart = text.index(after: afterLabel)
            guard let close = text[destinationStart...].firstIndex(of: ")"),
                  !text[destinationStart..<close].contains("\n") else { return nil }
            return (label, text.index(after: close))
        }
        if text[afterLabel] == "[" {
            let referenceStart = text.index(after: afterLabel)
            guard let referenceEnd = closingBracket(text, from: referenceStart) else { return nil }
            return (label, text.index(after: referenceEnd))
        }
        return nil
    }

    private static func closingBracket(_ text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                index = text.index(after: next)
                continue
            }
            if text[index] == "\n" { return nil }
            if text[index] == "]" { return index }
            index = text.index(after: index)
        }
        return nil
    }

    private static func consumingCodeSpan(_ text: String, at start: String.Index) -> (text: String, end: String.Index)? {
        guard text[start] == "`" else { return nil }
        let ticks = runLength(text, from: start, matching: "`")
        var index = text.index(start, offsetBy: ticks)
        while index < text.endIndex {
            if text[index] == "`" {
                let closing = runLength(text, from: index, matching: "`")
                if closing == ticks {
                    let raw = text[text.index(start, offsetBy: ticks)..<index].replacingOccurrences(of: "\n", with: " ")
                    return (raw, text.index(index, offsetBy: closing))
                }
                index = text.index(index, offsetBy: closing)
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func consumingAutolink(_ text: String, at start: String.Index) -> (value: String, end: String.Index)? {
        guard text[start] == "<" else { return nil }
        let contentStart = text.index(after: start)
        guard let close = text[contentStart...].firstIndex(of: ">") else { return nil }
        let inner = String(text[contentStart..<close])
        guard inner.hasPrefix("https://") || inner.hasPrefix("http://"),
              !inner.contains(where: { $0.isWhitespace }) else { return nil }
        return (inner, text.index(after: close))
    }

    private static func runLength(_ text: String, from index: String.Index, matching character: Character) -> Int {
        var count = 0
        var cursor = index
        while cursor < text.endIndex, text[cursor] == character {
            count += 1
            cursor = text.index(after: cursor)
        }
        return count
    }

    private static func shouldOmitDelimiter(_ text: String, at start: String.Index, character: Character, length: Int) -> Bool {
        if character == "*" { return true }
        if length != 1 { return true }
        let before = start > text.startIndex ? text[text.index(before: start)] : nil
        let end = text.index(start, offsetBy: length)
        let after = end < text.endIndex ? text[end] : nil
        let insideWord = (before?.isLetter == true || before?.isNumber == true)
            && (after?.isLetter == true || after?.isNumber == true)
        return !insideWord
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > summaryCharacterLimit else { return text }
        let end = text.index(text.startIndex, offsetBy: summaryCharacterLimit - 1)
        var clipped = String(text[..<end])
        while clipped.last?.isWhitespace == true { clipped.removeLast() }
        guard !clipped.isEmpty else { return "…" }
        return clipped + "…"
    }
}

struct NoveliaGitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    /// Release 正文。缺失或 JSON null 表示没有可展示的说明；网页回退不填写。
    let body: String?
    let draft: Bool
    let prerelease: Bool

    init(tag_name: String, html_url: String, body: String? = nil, draft: Bool, prerelease: Bool) {
        self.tag_name = tag_name
        self.html_url = html_url
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag_name = try container.decode(String.self, forKey: .tag_name)
        html_url = try container.decode(String.self, forKey: .html_url)
        // 旧响应和测试夹具可以没有 body；null 与缺省一样视为没有摘要。
        body = try container.decodeIfPresent(String.self, forKey: .body)
        draft = try container.decode(Bool.self, forKey: .draft)
        prerelease = try container.decode(Bool.self, forKey: .prerelease)
    }

    private enum CodingKeys: String, CodingKey {
        case tag_name, html_url, body, draft, prerelease
    }

    var version: NoveliaReleaseVersion? { NoveliaReleaseVersion(tag_name) }
    /// 提示里的短说明。没有开场文字时为 nil，对话框不另起一段。
    var summary: String? { NoveliaReleaseNotes.openingSummary(body) }
    /// 发现新版本对话框的说明。没有摘要时只保留原来的版本问句。
    var updatePromptMessage: String {
        let versionText = version?.display ?? tag_name
        let question = "Novelia \(versionText) 已发布，是否前往下载页面？"
        guard let summary else { return question }
        return question + "\n\n" + summary
    }
    var downloadPage: URL? {
        guard let url = URL(string: html_url), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "github.com", c.user == nil, c.password == nil,
              c.port == nil, c.path.hasPrefix("/Guanine000/novelia-swift/releases/tag/") else { return nil }
        return url
    }
    func shouldOffer(current: String, ignored: String) -> Bool {
        guard !draft, !prerelease, downloadPage != nil, let version,
              let installed = NoveliaReleaseVersion(current), version > installed else { return false }
        return NoveliaReleaseVersion(ignored) != version
    }
}

/// 手动检查 App 更新的结果；有新版本时同时设置 `NoveliaUpdateStore.release`，由根视图弹出下载提示。
enum NoveliaManualUpdateResult: Equatable {
    case available
    case upToDate(current: String)
    case failed
    case rateLimited
    /// 上一次手动检查仍在进行，本次不另发请求，界面不提示。
    case inProgress
}

private enum NoveliaUpdateError: Error { case rateLimited }

@MainActor
final class NoveliaUpdateStore: ObservableObject {
    static let enabledKey = "automaticallyCheckGitHubUpdates"
    static let ignoredKey = "ignoredGitHubReleaseVersion"
    @Published var release: NoveliaGitHubRelease?
    @Published private(set) var isCheckingManually = false
    private var checkedThisLaunch = false
    private var isChecking = false
    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
        defaults.register(defaults: [Self.enabledKey: true])
    }

    func check(force: Bool = false) async {
        guard defaults.bool(forKey: Self.enabledKey), !isChecking, force || !checkedThisLaunch else { return }
        checkedThisLaunch = true
        isChecking = true
        defer { isChecking = false }
        // 更新服务不可用时，不能中断阅读或登录。
        guard let candidate = try? await fetchLatest(), defaults.bool(forKey: Self.enabledKey) else { return }
        if candidate.shouldOffer(current: currentVersion, ignored: defaults.string(forKey: Self.ignoredKey) ?? "") {
            release = candidate
        }
    }

    /// “我的 → 版本 → 检查更新”：不受启动检查开关限制，也会再次提示之前忽略的版本。
    func checkManually() async -> NoveliaManualUpdateResult {
        guard !isCheckingManually else { return .inProgress }
        isCheckingManually = true
        defer { isCheckingManually = false }
        let candidate: NoveliaGitHubRelease
        do { candidate = try await fetchLatest() }
        catch NoveliaUpdateError.rateLimited { return .rateLimited }
        catch { return .failed }
        guard candidate.shouldOffer(current: currentVersion, ignored: "") else { return .upToDate(current: currentVersion) }
        release = candidate
        return .available
    }

    private func fetchLatest() async throws -> NoveliaGitHubRelease {
        do { return try await fetchAPIRelease() }
        catch {
            let primaryError = error
            // 匿名 API 按出口 IP 限流；正式版网页使用独立入口，跟随 latest 重定向取得同一发布标签。
            // 不解析网页正文，因此备用结果没有摘要；不使用镜像或携带账号令牌。备用入口失败时保留原错误以准确提示限流。
            do { return try await fetchReleasePage() }
            catch { throw primaryError }
        }
    }

    private func fetchAPIRelease() async throws -> NoveliaGitHubRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Guanine000/novelia-swift/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Novelia-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if (http.statusCode == 403 || http.statusCode == 429),
           http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw NoveliaUpdateError.rateLimited
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let candidate = try JSONDecoder().decode(NoveliaGitHubRelease.self, from: data)
        guard !candidate.draft, !candidate.prerelease, candidate.downloadPage != nil,
              candidate.version != nil else { throw URLError(.cannotParseResponse) }
        return candidate
    }

    private func fetchReleasePage() async throws -> NoveliaGitHubRelease {
        var request = URLRequest(url: URL(string: "https://github.com/Guanine000/novelia-swift/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("Novelia-iOS", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url else {
            throw URLError(.badServerResponse)
        }
        // 只采用重定向后的标签。不读取网页 HTML，所以没有 body，提示里不显示摘要。
        let candidate = NoveliaGitHubRelease(tag_name: url.lastPathComponent, html_url: url.absoluteString,
                                            draft: false, prerelease: false)
        guard candidate.downloadPage != nil, let version = candidate.version, !version.isPrerelease else {
            throw URLError(.cannotParseResponse)
        }
        return candidate
    }

    func ignore(_ candidate: NoveliaGitHubRelease) {
        defaults.set(candidate.version?.display, forKey: Self.ignoredKey)
        release = nil
    }
}
