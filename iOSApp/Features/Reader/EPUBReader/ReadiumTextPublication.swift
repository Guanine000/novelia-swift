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
    }

    private let resources: [String: Int]
    /// 只持有资源 href、没有章内位置时使用：每个资源向前填充「最后一个不晚于该资源的目录项」。
    /// 阅读时长分段依赖这个稳定分组，不能改成「该文件的第一项」。
    private let tocByResource: [Int?]
    private let tocByHref: [String: Int]
    private let anchors: [Anchor]

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
            anchors.append(Anchor(tocIndex: id, resource: resource, fragment: fragment))
        }
        // 没有章内位置的查询仍取最后一个不晚于该资源的条目，避免后续无目录文件被拆段。
        var best: Int?
        for resource in starts.indices {
            if let id = starts[resource] { best = max(best ?? id, id) }
            starts[resource] = best
        }
        self.resources = resources
        tocByResource = starts
        tocByHref = byHref
        self.anchors = anchors
    }

    /// 同一资源里的目录锚点（含 fragment；文件开头为 nil）。测试用来确认没有被后一项覆盖。
    func fragments(inResource resource: Int) -> [String?] {
        anchors.filter { $0.resource == resource }.map(\.fragment)
    }

    /// 同一资源里需要测量的锚点 id。没有 fragment 的项是文件开头，不查 DOM。
    func fragmentIDs(inResource resource: Int) -> [String] {
        anchors.compactMap { anchor in
            guard anchor.resource == resource, let fragment = anchor.fragment, !fragment.isEmpty else { return nil }
            return fragment
        }
    }

    /// 同一资源有多项且至少有一个章内锚点时，才需要读当前页的几何。
    func needsLayoutMeasurement(resource: Int) -> Bool {
        let items = anchors.filter { $0.resource == resource }
        return items.count > 1 && items.contains { $0.fragment?.isEmpty == false }
    }

    /// 用一次 DOM 测量决定高亮。`measurements == nil` 表示几何还不可用，当前文件回退到第一项。
    func highlightIndex(resource: Int, viewportProgression: Double?, measurements: [String: Double]?) -> Int? {
        ReadiumTOCGeometrySelection.index(
            anchors: anchors.map {
                ReadiumTOCGeometrySelection.Anchor(tocIndex: $0.tocIndex, resource: $0.resource, fragment: $0.fragment)
            },
            resource: resource,
            viewportProgression: viewportProgression,
            measurements: measurements
        )
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

/// 同一资源内，按锚点前缘的布局进度（不是正文字数比例）选择目录项。
/// 进度与 Readium 3.11 上报的 `locations.progression` 同一量纲：视口起点。
/// 一页或双页里同时能看见多节时，只高亮页首已经到达的最后一节；右栏才开始的下一节还不算当前。
enum ReadiumTOCGeometrySelection {
    struct Anchor {
        var tocIndex: Int
        var resource: Int?
        var fragment: String?
    }

    static func index(anchors: [Anchor], resource: Int, viewportProgression: Double?,
                      measurements: [String: Double]?) -> Int? {
        let ready = measurements != nil && viewportProgression != nil
        let positions: [Double?] = anchors.map { anchor in
            guard anchor.resource == resource, let measurements else { return nil }
            guard let fragment = anchor.fragment, !fragment.isEmpty else { return 0 }
            return measurements[fragment]
        }
        guard let selected = InFileTOCSelection.currentIndex(
            resources: anchors.map(\.resource),
            positions: positions,
            resource: resource,
            position: viewportProgression,
            positionsReady: ready
        ), anchors.indices.contains(selected) else { return nil }
        return anchors[selected].tocIndex
    }
}

/// 一次几何查询的身份。代次或资源变了，或者查的不是真实导航器，结果都必须丢掉。
struct ReadiumTOCMeasureToken: Equatable {
    var generation: Int
    var resource: Int
}

enum ReadiumTOCMeasureGate {
    static func shouldApply(requested: ReadiumTOCMeasureToken, latest: ReadiumTOCMeasureToken,
                            queriedRealNavigator: Bool) -> Bool {
        queriedRealNavigator && requested == latest
    }
}

/// 在当前可见文档里测量目录锚点。脚本是自有的，只调用 DOM 的公开几何；
/// 轴向与 Readium 3.11 `onScroll` 一致：非竖排滚动用 `scrollY / scrollHeight`，
/// 其余（分栏，以及竖排滚动）用从文档阅读起点起算的水平进度 `scrollX / scrollWidth`。
/// 分页模式下把元素前缘对齐到所在栏起点，避免页面内边距导致页首锚点永远大于视口起点，
/// 同时保留双页模式「右栏尚未到达页首」的语义。
enum ReadiumTOCGeometryScript {
    struct Snapshot: Equatable {
        /// `readium.link.href`，用来确认量到的是当前资源，而不是还没换掉的上一章。
        var href: String
        var viewportProgression: Double
        var found: [String: Double]
    }

    static func source(fragmentIDs: [String]) -> String? {
        guard JSONSerialization.isValidJSONObject(fragmentIDs),
              let data = try? JSONSerialization.data(withJSONObject: fragmentIDs),
              let literal = String(data: data, encoding: .utf8) else { return nil }
        return """
        (function() {
          var ids = \(literal);
          var root = document.scrollingElement || document.documentElement;
          var style = window.getComputedStyle(document.documentElement);
          var writingMode = style.writingMode || "";
          var vertical = writingMode.indexOf("vertical") === 0;
          var scrollOn = (document.documentElement.style.getPropertyValue("--USER__view") || "").trim() === "readium-scroll-on";
          var rtl = style.direction === "rtl" || writingMode === "vertical-rl";
          var colCount = parseInt(style.getPropertyValue("column-count"), 10);
          if (!(colCount > 1)) colCount = 1;
          var colWidth = window.innerWidth / colCount;
          function viewportProgression() {
            if (scrollOn && !vertical) {
              var height = root.scrollHeight;
              if (!(height > 0)) return null;
              return window.scrollY / height;
            }
            var width = root.scrollWidth;
            if (!(width > 0)) return null;
            var scrollPos = rtl ? Math.abs(window.scrollX) : window.scrollX;
            return scrollPos / width;
          }
          function elementProgression(rect) {
            if (scrollOn && !vertical) {
              var height = root.scrollHeight;
              if (!(height > 0)) return null;
              return Math.max(0, rect.top + window.scrollY - 1) / height;
            }
            var width = root.scrollWidth;
            if (!(width > 0)) return null;
            var scrollPos = rtl ? Math.abs(window.scrollX) : window.scrollX;
            var raw = rtl ? (window.innerWidth - rect.right) + scrollPos : rect.left + scrollPos;
            if (scrollOn) {
              return Math.max(0, raw - 1) / width;
            }
            var snapped = colWidth > 0 ? Math.floor(Math.max(0, raw + 1) / colWidth) * colWidth : Math.max(0, raw);
            return snapped / width;
          }
          var viewport = viewportProgression();
          var href = (typeof readium !== "undefined" && readium.link && typeof readium.link.href === "string") ? readium.link.href : "";
          var found = {};
          var missing = [];
          for (var i = 0; i < ids.length; i++) {
            var id = ids[i];
            var element = document.getElementById(id);
            if (!element) { missing.push(id); continue; }
            var value = elementProgression(element.getBoundingClientRect());
            if (value == null || !isFinite(value)) { missing.push(id); continue; }
            found[id] = value;
          }
          return JSON.stringify({ href: href, viewport: viewport, found: found, missing: missing });
        })()
        """
    }

    static func parse(jsonString: String) -> Snapshot? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let viewport = (object["viewport"] as? NSNumber)?.doubleValue
        guard let href = object["href"] as? String, !href.isEmpty,
              let viewport, viewport.isFinite, object["found"] is [String: Any] else { return nil }
        let foundObject = object["found"] as? [String: Any] ?? [:]
        var found: [String: Double] = [:]
        for (key, value) in foundObject {
            guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { continue }
            found[key] = number
        }
        return Snapshot(href: href, viewportProgression: viewport, found: found)
    }
}
