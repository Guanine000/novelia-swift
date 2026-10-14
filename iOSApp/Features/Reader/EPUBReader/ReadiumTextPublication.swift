import Foundation
import ReadiumShared
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
           let json = defaults.string(forKey: "readium.text.locator.v1.\(identity)"),
           let savedAt = defaults.object(forKey: "readium.text.time.v1.\(identity)") as? Date,
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
            manifest: Manifest(metadata: Metadata(title: source.bookTitle, languages: ["zh"], layout: .reflowable),
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
    private let resources: [String: Int]
    private let tocByResource: [Int?]
    private let tocByHref: [String: Int]

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
        for (id, link) in tableOfContents.enumerated() {
            let href = link.url().removingFragment()
            byHref[href.normalized.string] = id
            if let resource = Self.resourceIndex(for: href, resources: resources) {
                starts[resource] = id
            }
        }
        // 目录不一定按资源排序；保留旧行为，取最后一个不晚于当前位置的条目。
        var best: Int?
        for resource in starts.indices {
            if let id = starts[resource] { best = max(best ?? id, id) }
            starts[resource] = best
        }
        self.resources = resources
        tocByResource = starts
        tocByHref = byHref
    }

    func resourceIndex(for href: AnyURL) -> Int? {
        Self.resourceIndex(for: href, resources: resources)
    }

    func tocIndex(for href: AnyURL) -> Int? {
        if let resource = resourceIndex(for: href) { return tocByResource[resource] }
        return tocByHref[href.normalized.string]
    }

    private static func resourceIndex(for href: AnyURL, resources: [String: Int]) -> Int? {
        let href = href.normalized
        return resources[href.string] ?? resources[href.removingQuery().removingFragment().string]
    }
}
