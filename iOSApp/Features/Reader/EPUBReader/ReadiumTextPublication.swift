import Foundation
import ReadiumShared
import SwiftSoup
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif

/// 将已有的惰性 TXT / 在线章节交给 Readium，打开时不读取正文或触发网络请求。
/// 使用 Readium 公开的 Publication / Container API；未复制或修改上游源码。
@MainActor
enum ReadiumTextPublication {
    /// 先尝试本机精确定位；同步位置较新或分章改变时回退到共享单元／偏移。
    /// 仅读取，不修改同步时间戳；只有回退确实需要偏移换算时才读取正文。
    static func initialLocation(publication: Publication, source: TextChapterSource,
                                unit: Int, offset: Int?, identity: String?, updatedAt: Date?,
                                defaults: UserDefaults = .standard) async throws -> Locator? {
        guard publication.readingOrder.indices.contains(unit) else { return nil }
        if let identity,
           let json = defaults.string(forKey: ReadiumLocatorKeys.textLocator(identity: identity)),
           let savedAt = defaults.object(forKey: ReadiumLocatorKeys.textTime(identity: identity)) as? Date,
           savedAt >= (updatedAt ?? .distantPast),
           let value = try? JSONValue(jsonString: json),
           let saved = try? Locator(json: value, warnings: nil),
           publication.readingOrder.firstIndexWithHREF(saved.href) == unit {
            return saved
        }
        var location = await publication.locate(publication.readingOrder[unit])
        if let offset, offset > 0 {
            let html = try await source.chapterHTML(at: unit)
            location = location?.copy(locations: {
                $0.progression = EPUBChapterProgress.progression(offset: offset, length: EPUBChapterProgress.textLength(html: html))
            })
        }
        return location
    }

    static func make(source: TextChapterSource) -> Publication {
        let links = (0..<source.chapterCount).map { index in
            Link(href: source.chapterHref(at: index), mediaType: .xhtml,
                 title: source.tocEntry(containingUnit: index).map { source.toc[$0].title })
        }
        let toc = source.toc.compactMap { entry -> Link? in
            guard let index = entry.spineIndex, links.indices.contains(index) else { return nil }
            return links[index]
        }
        // 一个单元一个位置，不为了计算位置提前读取整本在线小说。
        // Readium 继续提供真实页面及章内 progression；这里的 position 不是页码。
        let positions = links.enumerated().map { index, link in
            [Locator(href: link.url(), mediaType: .xhtml, title: link.title,
                     locations: .init(progression: 0, totalProgression: Double(index) / Double(max(1, links.count)), position: index + 1))]
        }
        return Publication(
            manifest: Manifest(metadata: Metadata(title: source.bookTitle,
                                                  languages: [source.displayProjection.htmlLanguageTag ?? "zh"],
                                                  layout: .reflowable),
                               readingOrder: links, tableOfContents: toc),
            container: TextContainer(source: source, links: links),
            servicesBuilder: PublicationServicesBuilder(positions: { _ in TextPositions(positions: positions) }))
    }
}

private struct TextPositions: PositionsService {
    let positions: [[Locator]]
    func positionsByReadingOrder() async -> ReadResult<[[Locator]]> { .success(positions) }
}

/// 每次请求返回新的 Resource，避免 DataResource 缓存失败后无法重试。
private final class TextContainer: Container {
    let sourceURL: AbsoluteURL? = nil
    let entries: Set<AnyURL>
    private let resources: [AnyURL: Int]
    private let source: TextChapterSource

    @MainActor
    init(source: TextChapterSource, links: [Link]) {
        self.source = source
        resources = Dictionary(uniqueKeysWithValues: links.enumerated().map { ($0.element.url(), $0.offset) })
        entries = Set(resources.keys)
    }

    subscript(url: any URLConvertible) -> Resource? {
        guard let index = resources[url.anyURL.removingQuery().removingFragment()] else { return nil }
        return DataResource { [source] in
            do {
                try Task.checkCancellation()
                let html = try await source.chapterHTML(at: index)
                try Task.checkCancellation()
                // 不固化主题色，由 ReadiumCSS 统一处理明暗主题。
                let css = """
                h1 { font-size: 1.35em; text-indent: 0; margin: 0.4em 0 1.2em; }
                p { text-indent: 2em; line-height: 1.75; margin: 0 0 0.55em; text-align: justify; }
                .secondary { opacity: 0.7; }
                .subtitle, .note { text-indent: 0; opacity: 0.7; }
                .note { text-align: center; }
                """
                return .success(Data(html.replacingOccurrences(of: "</head>", with: "<style>\(css)</style></head>").utf8))
            } catch {
                return .failure(ReadError.wrap(error) ?? .access(.other(error)))
            }
        }
    }
}

/// 首屏、翻页与目录高亮共用的静态导航索引。
/// 不在每次视图刷新时对每条目录再次线性扫描 readingOrder。
struct ReadiumNavigationIndex {
    private struct Anchor {
        let tocIndex: Int
        let resource: Int?
        let fragment: String?
        var progression: Double?
    }

    private let resources: [String: Int]
    private let tocLinks: [Link]
    /// 只持有资源 href、没有章内位置时使用：每个资源向前填充「最后一个不晚于该资源的目录项」。
    /// 阅读时长分段依赖这个稳定分组，不能改成「该文件的第一项」。
    private let tocByResource: [Int?]
    private let tocByHref: [String: Int]
    private var anchors: [Anchor]
    private var progressionsReady = false

    init(readingOrder: [Link], tableOfContents: [Link]) {
        var resources: [String: Int] = [:]
        resources.reserveCapacity(readingOrder.count)
        for (index, link) in readingOrder.enumerated() {
            let href = link.url().normalized.string
            // 与 Readium firstIndexWithHREF 相同：重复 href 取首次出现。
            if resources[href] == nil { resources[href] = index }
        }
        var starts = [Int?](repeating: nil, count: readingOrder.count)
        var byHref: [String: Int] = [:]
        var anchors: [Anchor] = []
        anchors.reserveCapacity(tableOfContents.count)
        for (id, link) in tableOfContents.enumerated() {
            let url = link.url()
            let href = url.removingFragment()
            byHref[href.normalized.string] = id
            let resource = Self.resourceIndex(for: href, resources: resources)
            if let resource {
                starts[resource] = id
            }
            let fragment = url.fragment.flatMap { EPUBContainer.tocFragment(in: "#\($0)") }
                ?? EPUBContainer.tocFragment(in: url.string)
            anchors.append(Anchor(tocIndex: id, resource: resource, fragment: fragment, progression: nil))
        }
        // 没有章内位置的查询仍取最后一个不晚于该资源的条目，避免后续无目录文件被拆段。
        var best: Int?
        for resource in starts.indices {
            if let id = starts[resource] { best = max(best ?? id, id) }
            starts[resource] = best
        }
        self.resources = resources
        tocLinks = tableOfContents
        tocByResource = starts
        tocByHref = byHref
        self.anchors = anchors
    }

    /// 同一资源里的目录锚点（含 fragment；文件开头为 nil）。测试用来确认没有被后一项覆盖。
    func fragments(inResource resource: Int) -> [String?] {
        anchors.filter { $0.resource == resource }.map(\.fragment)
    }

    /// 写入已经算好的 progression，并标记目录位置可用。键是目录序号。
    func applying(progressions: [Int: Double]) -> ReadiumNavigationIndex {
        var copy = self
        for index in copy.anchors.indices {
            if let value = progressions[copy.anchors[index].tocIndex] {
                copy.anchors[index].progression = value
            }
        }
        copy.progressionsReady = true
        return copy
    }

    /// 打开书籍时为每条目录调用 `publication.locate`。
    /// Readium 3.11 的 `DefaultLocatorService.locate(_:Link)` 只在没有 fragment 时给出 progression 0，
    /// 带 fragment 时把 progression 留空。空值和 0 都无法区分同一文件里的锚点，
    /// 因此同一资源有多项且 locate 没有 progression 时，按正文里该锚点之前的可见文本比例补上。
    /// 一个资源只有一条目录时不读正文：整章都高亮这一项。
    func locatingTOCProgressions(in publication: Publication) async -> ReadiumNavigationIndex {
        var copy = self
        var perResource: [Int: Int] = [:]
        for anchor in copy.anchors {
            if let resource = anchor.resource { perResource[resource, default: 0] += 1 }
        }
        var htmlByResource: [Int: String] = [:]
        for index in copy.anchors.indices {
            let anchor = copy.anchors[index]
            guard tocLinks.indices.contains(anchor.tocIndex) else { continue }
            let link = tocLinks[anchor.tocIndex]
            let located = await publication.locate(link)
            if let progression = located?.locations.progression {
                copy.anchors[index].progression = progression
                continue
            }
            let siblings = anchor.resource.flatMap { perResource[$0] } ?? 0
            guard let fragment = anchor.fragment, !fragment.isEmpty, siblings > 1,
                  let resource = anchor.resource else {
                copy.anchors[index].progression = 0
                continue
            }
            if htmlByResource[resource] == nil {
                htmlByResource[resource] = await Self.resourceHTML(resource, in: publication) ?? ""
            }
            copy.anchors[index].progression = ReadiumTOCFragmentProgression.progression(
                fragment: fragment, html: htmlByResource[resource] ?? "")
        }
        copy.progressionsReady = true
        return copy
    }

    private static func resourceHTML(_ resource: Int, in publication: Publication) async -> String? {
        guard publication.readingOrder.indices.contains(resource),
              let item = publication.get(publication.readingOrder[resource]),
              case .success(let html) = await item.read().asString() else { return nil }
        return html
    }

    func resourceIndex(for href: AnyURL) -> Int? {
        Self.resourceIndex(for: href, resources: resources)
    }

    /// Readium 3.11 本地资源形如 readium://<会话 UUID>/<完整包内路径>。
    /// 只去掉已知服务器来源，不做文件名/路径后缀猜测；远程资源必须精确匹配完整 URL。
    /// URL 仅用于内存匹配，不进入日志；未知或固定版 wrapper 返回 nil。
    func resourceIndex(forDocumentURL url: URL) -> Int? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.query = nil
        components.fragment = nil
        if let string = components.url?.absoluteString, let href = AnyURL(string: string),
           let index = resourceIndex(for: href) { return index }
        guard components.scheme == "readium", let host = components.host, UUID(uuidString: host) != nil else { return nil }
        let path = String(components.percentEncodedPath.drop(while: { $0 == "/" }))
        guard let href = AnyURL(string: path) else { return nil }
        return resourceIndex(for: href)
    }

    func tocIndex(for href: AnyURL) -> Int? {
        if let resource = resourceIndex(for: href) { return tocByResource[resource] }
        return tocByHref[href.normalized.string]
    }

    /// 同一资源内取 progression 不晚于当前 locator 的最后一项。
    /// 目录位置还没算出来时，回退到该资源的第一项。
    func tocIndex(for locator: Locator) -> Int? {
        guard let resource = resourceIndex(for: locator.href) else {
            return tocByHref[locator.href.normalized.string]
                ?? tocByHref[locator.href.removingQuery().removingFragment().normalized.string]
        }
        let positions: [Double?] = anchors.map { anchor in
            if let progression = anchor.progression { return progression }
            if anchor.fragment == nil, progressionsReady { return 0 }
            return nil
        }
        let position: Double? = progressionsReady ? (locator.locations.progression ?? 0) : nil
        return InFileTOCSelection.currentIndex(
            resources: anchors.map(\.resource),
            positions: positions,
            resource: resource,
            position: position,
            positionsReady: progressionsReady
        )
    }

    /// 不知道页内位置时，该资源的第一项；资源自己没有目录项时，用更早资源里阅读顺序最后的一项。
    func tocIndex(atStartOfResource resource: Int) -> Int? {
        InFileTOCSelection.currentIndex(
            resources: anchors.map(\.resource),
            positions: Array(repeating: Optional<Double>.none, count: anchors.count),
            resource: resource,
            position: Optional<Double>.none,
            positionsReady: false
        )
    }

    private static func resourceIndex(for href: AnyURL, resources: [String: Int]) -> Int? {
        let href = href.normalized
        return resources[href.string] ?? resources[href.removingQuery().removingFragment().string]
    }
}

/// 用锚点之前的可见文本 UTF-16 长度占全文的比例，近似 Readium 的资源内 progression。
/// 跳过 script / style。找不到锚点时返回 nil，不能把失败记成 0，否则又会落到最后一项。
enum ReadiumTOCFragmentProgression {
    static func progression(fragment: String?, html: String) -> Double? {
        guard let wanted = EPUBTOCHighlight.normalizedFragment(fragment) else { return 0 }
        guard let document = try? SwiftSoup.parse(html), let body = document.body() else { return nil }
        var total = 0
        var before: Int?
        func walk(_ node: Node) {
            if let element = node as? Element {
                let name = element.tagName().lowercased()
                if name == "script" || name == "style" { return }
                if before == nil, matches(element, wanted) { before = total }
            }
            if let text = node as? TextNode {
                total += text.text().utf16.count
                return
            }
            for child in node.getChildNodes() { walk(child) }
        }
        walk(body)
        guard let before else { return nil }
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(before) / Double(total)))
    }

    private static func matches(_ element: Element, _ fragment: String) -> Bool {
        for attribute in ["id", "name"] {
            guard let value = try? element.attr(attribute), !value.isEmpty,
                  let key = EPUBTOCHighlight.normalizedFragment(value) else { continue }
            if key == fragment { return true }
        }
        return false
    }
}
