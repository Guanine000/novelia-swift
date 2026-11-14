import Foundation
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif
import ImageIO
import UIKit

// MARK: - 书内图片

/// 书内一张图片：`path` 为 ZIP 内路径，`spineIndex` 为首次出现的章节（manifest 中未被引用的图片为 nil）。
struct EPUBImageEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let spineIndex: Int?
}

/// 图片尺寸读取与按需缩小解码（缩略图、查看器共用），不在主线程以外持有 UIKit 对象。
enum EPUBImageDecoding {
    /// 不解码像素，只读取图片的像素尺寸。
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 长边不超过 `maxPixelLength` 的图片（保持方向）；`nil` 表示按原尺寸解码。
    static func image(from data: Data, maxPixelLength: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelLength {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelLength
        } else if let size = pixelSize(of: data) {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(size.width, size.height)
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Readium 图片兼容

/// 直接位于 body 下的连续 img 会组成匿名行框；Readium 的孤行保护会让 WebKit
/// 把第二张图片切到相邻栏，即使单张图片完全放得下一页。只把这类独立图片改为
/// 块元素，段落内的小图仍按书籍样式排版。独立 SVG 封面补齐媒体限高与防跨栏规则，
/// 避免 ReadiumCSS 的 XHTML 默认命名空间使其 svg 选择器失效。同时修正 SVG 属性大小写。
/// 由 Readium 的资源映射注入，不修改原书；块布局仅用于可重排书籍。
enum EPUBReadiumImageLayout {
    /// 部分转换器把 SVG 属性名转成小写。XHTML 按 XML 区分大小写，丢失 viewBox
    /// 后图片会按原始像素绘制并被 SVG 视口裁切。仅修正已知属性名，不重写尺寸或原书。
    static func normalizingSVGAttributes(inHTML html: String) -> String {
        let tokens = try! NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)\s*>|<[A-Za-z][\w:-]*\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive])
        let attributes = try! NSRegularExpression(
            pattern: #"\s+([\w:-]+)\s*=\s*(?:"[^"]*"|'[^']*')"#)
        let names = ["viewbox": "viewBox", "preserveaspectratio": "preserveAspectRatio"]
        var result = html as NSString
        for token in tokens.matches(in: html, range: NSRange(location: 0, length: result.length)).reversed() {
            let tag = result.substring(with: token.range) as NSString
            guard tag.range(of: #"^<svg(?=\s|/?>)"#, options: [.regularExpression, .caseInsensitive]).location == 0 else { continue }
            let matches = attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length))
            var patched = tag
            for attribute in matches.reversed() {
                let range = attribute.range(at: 1)
                let name = tag.substring(with: range)
                guard let canonical = names[name.lowercased()], name != canonical else { continue }
                // 无法判断重复属性的作者意图时保留原标签，避免引入重复的 XML 属性。
                guard matches.filter({ tag.substring(with: $0.range(at: 1)).lowercased() == name.lowercased() }).count == 1 else { continue }
                patched = patched.replacingCharacters(in: range, with: canonical) as NSString
            }
            result = result.replacingCharacters(in: token.range, with: patched as String) as NSString
        }
        return result as String
    }

    static func keepingStandaloneImagesTogether(inHTML html: String) -> String {
        guard let head = html.range(of: "</head>", options: .caseInsensitive) else { return html }
        let style = """
        <style id="novelia-standalone-images">
        @namespace svg url("http://www.w3.org/2000/svg");
        body > img {
            display: block !important;
            -webkit-column-break-inside: avoid !important;
            page-break-inside: avoid !important;
            break-inside: avoid !important;
        }
        body > svg|svg, body > div > svg|svg:only-child {
            display: block;
            width: auto;
            height: auto;
            max-width: var(--RS__maxMediaWidth, 100%);
            max-height: var(--RS__maxMediaHeight, 95vh) !important;
            margin-left: auto;
            margin-right: auto;
            -webkit-column-break-inside: avoid !important;
            page-break-inside: avoid !important;
            break-inside: avoid !important;
        }
        </style>
        """
        var result = html
        result.insert(contentsOf: style, at: head.lowerBound)
        return result
    }
}

// MARK: - Readium 页面底色

/// 忽略近白的页面、段落与行内底色；彩色底、边框和背景图片保留书内样式。
/// 相同配置不重复写 DOM；主题观察只响应实际主题标记变化，忽略自身背景与其他样式修改。
enum EPUBReadiumPageBackground {
    static func script(ignoresNearWhite: Bool, threshold: Double) -> String {
        return """
        (function () {
          function apply() {
            var configuration = '\(ignoresNearWhite)|\(threshold)';
            var changed = document.__noveliaPageAppearance !== configuration;
            var elements = [document.documentElement].concat(Array.from(document.querySelectorAll('body, body *')));
            elements.forEach(function (el) {
              if (!el || !el.__noveliaPageBackground) return;
              var saved = el.__noveliaPageBackground;
              var owned = el.style.getPropertyValue('background-color') === 'transparent'
                  && el.style.getPropertyPriority('background-color') === 'important';
              if (changed && owned) {
                if (saved.value) el.style.setProperty('background-color', saved.value, saved.priority);
                else el.style.removeProperty('background-color');
              }
              if (changed || !owned) delete el.__noveliaPageBackground;
            });
            function color(el) {
              if (!el) return null;
              var css = getComputedStyle(el).backgroundColor;
              var match = css.match(/^rgba?\\(([^)]+)\\)$/);
              if (!match) return null;
              var values = match[1].split(',').map(Number);
              return { css: css, rgb: values.slice(0, 3), alpha: values.length > 3 ? values[3] : 1 };
            }
            if (\(ignoresNearWhite)) {
              elements.forEach(function (el) {
                if (!el) return;
                var c = color(el);
                if (!el.__noveliaPageBackground && c && c.alpha > 0 && c.rgb.every(function (v) { return v >= \(threshold * 255); })) {
                  el.__noveliaPageBackground = {
                    value: el.style.getPropertyValue('background-color'),
                    priority: el.style.getPropertyPriority('background-color')
                  };
                  el.style.setProperty('background-color', 'transparent', 'important');
                }
              });
            }
            document.__noveliaPageAppearance = configuration;
            var root = color(document.documentElement), body = color(document.body);
            return root && root.alpha > 0 ? root.css : (body ? body.css : '');
          }
          var key = '\(ignoresNearWhite)|\(threshold)';
          var state = document.__noveliaWhiteBackgroundObserver;
          if (state && state.key !== key) {
            state.observer.disconnect();
            delete document.__noveliaWhiteBackgroundObserver;
            state = null;
          }
          if (\(ignoresNearWhite) && !state) {
            var appearance = function () { return document.documentElement.style.getPropertyValue('--USER__appearance'); };
            state = { key: key, appearance: appearance() };
            state.observer = new MutationObserver(function () {
              var next = appearance();
              if (next === state.appearance) return;
              // 先记下主题再处理背景；自身 background-color 改动不会再次触发处理。
              state.appearance = next;
              apply();
            });
            state.observer.observe(document.documentElement, {attributes:true,attributeFilter:['style']});
            document.__noveliaWhiteBackgroundObserver = state;
          }
          return apply();
        })()
        """
    }
}

// MARK: - 书内脚本禁用（Readium 可选）

/// 部分书籍自带脚本接管交互（如掌阅风格注释脚本删掉链接 href、按住时显示自绘气泡），
/// 使 Readium 下的表现与 YueduCoreText（排版前总会剥离脚本）不同。用户开启
/// “禁用书内脚本”后，Readium 打开 EPUB 时按此处规则改写资源；Readium 自身注入的脚本不受影响。
enum EPUBScriptRemoval {
    /// 是否为需要清空的脚本资源（按扩展名判断）。
    static func isScriptResource(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".js") || lower.hasSuffix(".mjs")
    }

    /// 是否为需要剔除脚本的章节文档。
    static func isHTMLResource(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    /// 去掉 `<script>` 元素和标签上的 `on…=` 事件属性；不含脚本时原样返回。
    static func removingScripts(fromHTML html: String) -> String {
        var discarded = 0
        var result = EPUBContainer.stripScripts(from: html, counter: &discarded)
        guard let handler = try? NSRegularExpression(
            pattern: "(<[A-Za-z][^>]*?)\\s+on[A-Za-z]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)",
            options: [.caseInsensitive]) else { return result }
        // 一个标签可能有多个事件属性，每轮去掉每个标签中的一个，直到没有为止。
        while true {
            let range = NSRange(location: 0, length: (result as NSString).length)
            guard handler.firstMatch(in: result, range: range) != nil else { break }
            result = handler.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }
        return result
    }

    /// 隐藏正文中设计为弹出显示的脚注正文（`epub:type` 含 footnote 或 note），点按注释仍由弹层显示。
    /// 这类正文原本常由书内脚本藏起；禁用脚本后不处理会以方框留在正文中。章末尾注
    /// （endnote／rearnote）和多看章末注释列表不隐藏，避免整段注释章节消失。
    /// 只在已有 `<head>` 时注入，不改动其他结构。
    static func hidingPopupNoteBodies(inHTML html: String) -> String {
        guard let head = html.range(of: "</head>", options: .caseInsensitive) else { return html }
        let style = """
        <style>@namespace epub "http://www.idpf.org/2007/ops";
        *[epub|type~="footnote"], *[epub|type~="note"] { display: none !important; }
        *[epub\\:type~="footnote"], *[epub\\:type~="note"] { display: none !important; }</style>
        """
        var result = html
        result.insert(contentsOf: style, at: head.lowerBound)
        return result
    }
}

// MARK: - 注释正文识别（Readium 未标 noteref 的注释链接）

/// Readium 只对 `<a epub:type="noteref">` 弹出注释；多看及 Sigil 注释插件生成的
/// `<a class="duokan-footnote" href="#note_1">` 没有该属性，会被当成普通链接跳到章末。
/// 这里按链接目标判断是否为注释正文，规则与 YueduCoreText 的 `collectFootnotes` 一致：
/// 带 id、class 含 "footnote" 的 `<li>`，或 `epub:type` 含 footnote／endnote／note／rearnote 的元素。
/// 只看目标，不猜测普通锚点，未命中的链接仍照常跳转。
enum EPUBFootnoteTarget {
    /// 文档中 id 为 `id` 的注释正文的内部 HTML；不是注释或为空时返回 nil。
    static func noteHTML(id: String, inDocument html: String) -> String? {
        guard !id.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let openRegex = try? NSRegularExpression(
            pattern: "<([A-Za-z][\\w:-]*)\\b([^>]*?\\sid\\s*=\\s*[\"']\(escaped)[\"'][^>]*?)(/?)>",
            options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let open = openRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              open.range(at: 3).length == 0 else { return nil }
        let tag = ns.substring(with: open.range(at: 1)).lowercased()
        let attributes = ns.substring(with: open.range(at: 2))
        guard isNoteBody(tag: tag, attributes: attributes) else { return nil }

        // 找到同名标签的配对结束标签（计入嵌套）。
        guard let tagRegex = try? NSRegularExpression(
            pattern: "<(/?)\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*?(/?)>",
            options: [.caseInsensitive]) else { return nil }
        let start = open.range.location + open.range.length
        var depth = 1
        var end = ns.length
        for match in tagRegex.matches(in: html, range: NSRange(location: start, length: ns.length - start)) {
            if match.range(at: 2).length > 0 { continue }
            depth += match.range(at: 1).length > 0 ? -1 : 1
            if depth == 0 { end = match.range.location; break }
        }
        let inner = ns.substring(with: NSRange(location: start, length: end - start))
        let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : inner
    }

    private static func isNoteBody(tag: String, attributes: String) -> Bool {
        if tag == "li", let classes = attributeValue("class", in: attributes),
           classes.lowercased().contains("footnote") {
            return true
        }
        guard let epubType = attributeValue("epub:type", in: attributes) else { return false }
        let tokens = epubType.lowercased().split(whereSeparator: \.isWhitespace)
        return tokens.contains { ["footnote", "endnote", "note", "rearnote"].contains($0) }
    }

    private static func attributeValue(_ name: String, in attributes: String) -> String? {
        let pattern = "(?:^|\\s)\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = attributes as NSString
        guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 2))
    }
}

// MARK: - NCX 目录解析（XMLParser）

enum NCXParser {
    /// 按先序返回目录点；嵌套 navPoint 的层级逐层加一，父项排在子项之前。
    static func parse(xml: String) -> [(title: String, href: String, level: Int)] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private final class Point {
            var title = ""
            var href: String?
            var emitted = false
        }

        var points: [(title: String, href: String, level: Int)] = []
        /// 尚未结束的 navPoint；子项开始前先输出父项，保证先序。
        private var stack: [Point] = []
        private var isCollectingText = false

        private func emit(_ point: Point, level: Int) {
            guard !point.emitted else { return }
            point.emitted = true
            let title = point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = point.href, !title.isEmpty {
                points.append((XMLValueParser.decodeEntities(title), href, level))
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "navPoint" {
                if let parent = stack.last { emit(parent, level: stack.count - 1) }
                stack.append(Point())
            }
            if name == "content", let point = stack.last, point.href == nil {
                point.href = attributes["src"]
            }
            if name == "text", !stack.isEmpty {
                isCollectingText = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingText { stack.last?.title += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if isCollectingText, let text = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.title += text
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "text" {
                isCollectingText = false
            }
            if name == "navPoint", let point = stack.last {
                emit(point, level: stack.count - 1)
                stack.removeLast()
            }
        }
    }
}

// MARK: - UIColor 工具

extension UIColor {
    /// RGB 整数分量（0-255），用于宿主级 CSS 颜色改写。
    var rgbComponents: (Int, Int, Int) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return (0, 0, 0)
        }
        return (Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}
