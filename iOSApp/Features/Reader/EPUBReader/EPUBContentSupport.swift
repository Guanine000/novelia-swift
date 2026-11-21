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

// MARK: - 横排假 vrtl 悬挂缩进兼容

/// 部分由日文／台版竖排模板（如角川／电书协 EPUB 3）改成的横排书会删掉 `writing-mode: vertical-rl`，
/// 但仍保留 `<html class="vrtl">` 与 `.vrtl .h-indent-* { text-indent: -X; padding-top: X; }`。
/// 在横排模式下这会把行首（如注释编号「注1：」）拉出左边界，在多栏分页下溢到前一页右边缘。
/// 当书籍本身不是竖排时，将此类 `.vrtl` 规则块的 `padding-top` 转为 `padding-left`，既消除溢出又保留悬挂缩进。
enum EPUBHorizontalLayoutCompatibility {
    private static let verticalWritingModeRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:-(?:epub|webkit)-)?writing-mode\s*:\s*vertical-(?:rl|lr)\b"#
    )
    private static let ruleBlockRegex = try! NSRegularExpression(
        pattern: #"([^{}@]+)\{([^{}]*)\}"#
    )
    private static let vrtlSelectorRegex = try! NSRegularExpression(
        pattern: #"(?i)\.vrtl(?![A-Za-z0-9_-])"#
    )
    private static let negativeIndentRegex = try! NSRegularExpression(
        pattern: #"(?i)\btext-indent\s*:\s*-\s*(?:[0-9]*\.[0-9]+|[0-9]+)\s*(?:em|rem|px|pt|%)\b"#
    )
    private static let positivePaddingLeftRegex = try! NSRegularExpression(
        pattern: #"(?i)\bpadding-left\s*:\s*(?:0*[1-9][0-9]*(?:\.[0-9]+)?|0*\.[0-9]*[1-9][0-9]*)\s*(?:em|rem|px|pt|%)\b"#
    )
    private static let positivePaddingTopRegex = try! NSRegularExpression(
        pattern: #"(?i)\bpadding-top\s*:\s*((?:0*[1-9][0-9]*(?:\.[0-9]+)?|0*\.[0-9]*[1-9][0-9]*)\s*(?:em|rem|px|pt|%))(\s*!important)?\s*;?"#
    )

    static func isCSSResource(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "css"
    }

    static func containsVerticalWritingMode(_ css: String) -> Bool {
        let ns = css as NSString
        return verticalWritingModeRegex.firstMatch(in: css, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func normalizingHangingIndentsForHorizontal(in css: String) -> String {
        guard !css.isEmpty,
              css.range(of: "vrtl", options: .caseInsensitive) != nil,
              !containsVerticalWritingMode(css) else { return css }

        let ns = css as NSString
        let matches = ruleBlockRegex.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }

        var output = ""
        var cursor = 0
        for match in matches {
            let selector = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            let nsSelector = selector as NSString
            let nsBody = body as NSString
            guard vrtlSelectorRegex.firstMatch(in: selector, range: NSRange(location: 0, length: nsSelector.length)) != nil,
                  negativeIndentRegex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)) != nil,
                  positivePaddingLeftRegex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)) == nil,
                  let topMatch = positivePaddingTopRegex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length))
            else { continue }

            let value = nsBody.substring(with: topMatch.range(at: 1))
            let replacement = "padding-left: \(value) !important; padding-top: 0;"
            let rewrittenBody = nsBody.replacingCharacters(in: topMatch.range, with: replacement)

            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "\(selector){\(rewrittenBody)}"
            cursor = match.range.location + match.range.length
        }
        return cursor == 0 ? css : output + ns.substring(from: cursor)
    }
}

// MARK: - 按章裁剪未使用的 CSS 类规则
//
// 日本 EBPAJ / 角川 / Play Books 及 Calibre 转换的 EPUB 样式表常含上千条全局工具类规则，
// 而单个章节通常只用到其中几个 class。YueduCoreText 的样式级联会对每个 DOM 节点线性遍历全部规则，
// 提前移除“要求了本章 HTML 中根本不存在的 `.class`”的普通规则，可显著降低大章首开耗时。
// 规则：
// - 仅对顶层普通样式规则做保守裁剪；`@font-face`、`@media`、`@page`、`@import` 等 `@` 规则原样保留；
// - 含 `:not(`、`:is(`、`:where(`、`:has(` 或反斜杠转义的选择器保守保留；
// - 方括号属性选择器（如 `[href="a.html"]`）和括号内的 `.` 不当作类名；
// - 逗号分隔的选择器列表中只要有任意一项可能命中，即保留命中的子项。
enum EPUBCSSPruning {
    private static let classAttributeRegex = try! NSRegularExpression(
        pattern: #"(?i)\bclass\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>`]+))"#
    )

    static func usedClasses(in html: String) -> Set<String> {
        let ns = html as NSString
        let matches = classAttributeRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result: Set<String> = []
        result.reserveCapacity(matches.count)
        for match in matches {
            for group in 1...3 {
                let range = match.range(at: group)
                guard range.location != NSNotFound else { continue }
                let value = ns.substring(with: range)
                for token in value.split(whereSeparator: { $0.isWhitespace }) {
                    result.insert(String(token))
                }
                break
            }
        }
        return result
    }

    static func pruningUnusedClassRules(in css: String, html: String) -> String {
        pruningUnusedClassRules(in: css, usedClasses: usedClasses(in: html))
    }

    static func pruningUnusedClassRules(in css: String, usedClasses: Set<String>) -> String {
        guard css.utf8.count > 256 else { return css }
        let bytes = Array(css.utf8)
        let count = bytes.count
        var output: [UInt8] = []
        output.reserveCapacity(min(count, 8192))

        var i = 0
        while i < count {
            // 跳过空白与注释
            if isASCIIWhitespace(bytes[i]) {
                i += 1
                continue
            }
            if bytes[i] == 0x2F, i + 1 < count, bytes[i + 1] == 0x2A { // /*
                i += 2
                while i + 1 < count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                i = min(count, i + 2)
                continue
            }

            // `@` 规则：原样保留整个声明（直到 `;`）或整个块（直到配对 `}`）
            if bytes[i] == 0x40 { // @
                let start = i
                var depth = 0
                var quote: UInt8 = 0
                while i < count {
                    let b = bytes[i]
                    if quote != 0 {
                        if b == 0x5C { i = min(count, i + 2); continue } // \
                        if b == quote { quote = 0 }
                        i += 1
                        continue
                    }
                    if b == 0x2F, i + 1 < count, bytes[i + 1] == 0x2A {
                        i += 2
                        while i + 1 < count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                        i = min(count, i + 2)
                        continue
                    }
                    if b == 0x22 || b == 0x27 { quote = b; i += 1; continue }
                    if b == 0x7B { depth += 1; i += 1; continue } // {
                    if b == 0x7D { // }
                        depth -= 1
                        i += 1
                        if depth <= 0 { break }
                        continue
                    }
                    if b == 0x3B, depth == 0 { i += 1; break } // ;
                    i += 1
                }
                output.append(contentsOf: bytes[start..<i])
                output.append(0x0A)
                continue
            }

            // 普通样式规则：selectorList { body }
            let selectorStart = i
            var quote: UInt8 = 0
            while i < count {
                let b = bytes[i]
                if quote != 0 {
                    if b == 0x5C { i = min(count, i + 2); continue }
                    if b == quote { quote = 0 }
                    i += 1
                    continue
                }
                if b == 0x2F, i + 1 < count, bytes[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                    i = min(count, i + 2)
                    continue
                }
                if b == 0x22 || b == 0x27 { quote = b; i += 1; continue }
                if b == 0x7B || b == 0x7D { break } // { or stray }
                i += 1
            }
            guard i < count, bytes[i] == 0x7B else {
                // 异常未闭合尾部，保守原样保留
                output.append(contentsOf: bytes[selectorStart..<count])
                break
            }
            let selectorEnd = i
            let blockStart = i
            var depth = 0
            quote = 0
            while i < count {
                let b = bytes[i]
                if quote != 0 {
                    if b == 0x5C { i = min(count, i + 2); continue }
                    if b == quote { quote = 0 }
                    i += 1
                    continue
                }
                if b == 0x2F, i + 1 < count, bytes[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
                    i = min(count, i + 2)
                    continue
                }
                if b == 0x22 || b == 0x27 { quote = b; i += 1; continue }
                if b == 0x7B { depth += 1 }
                else if b == 0x7D {
                    depth -= 1
                    i += 1
                    if depth <= 0 { break }
                    continue
                }
                i += 1
            }
            let blockEnd = i

            let selectorText = String(decoding: bytes[selectorStart..<selectorEnd], as: UTF8.self)
            let keptSelectors = splitSelectors(selectorText).filter { selectorCouldMatch($0, usedClasses: usedClasses) }
            if !keptSelectors.isEmpty {
                let joined = keptSelectors.joined(separator: ", ")
                output.append(contentsOf: joined.utf8)
                output.append(contentsOf: bytes[blockStart..<blockEnd])
                output.append(0x0A)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    private static func splitSelectors(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        var quote: Character? = nil
        var escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if let q = quote {
                current.append(ch)
                if ch == "\\" { escaped = true }
                else if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "(" { parenDepth += 1; current.append(ch); continue }
            if ch == ")" { parenDepth = max(0, parenDepth - 1); current.append(ch); continue }
            if ch == "[" { bracketDepth += 1; current.append(ch); continue }
            if ch == "]" { bracketDepth = max(0, bracketDepth - 1); current.append(ch); continue }
            if ch == ",", parenDepth == 0, bracketDepth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    private static func selectorCouldMatch(_ selector: String, usedClasses: Set<String>) -> Bool {
        let lower = selector.lowercased()
        // 含转义或逻辑伪类选择器时保守保留，避免误删。
        if selector.contains("\\") || lower.contains(":not(") || lower.contains(":is(")
            || lower.contains(":where(") || lower.contains(":has(") {
            return true
        }
        let bytes = Array(selector.utf8)
        let count = bytes.count
        var i = 0
        var parenDepth = 0
        var bracketDepth = 0
        var quote: UInt8 = 0
        while i < count {
            let b = bytes[i]
            if quote != 0 {
                if b == 0x5C { i = min(count, i + 2); continue }
                if b == quote { quote = 0 }
                i += 1
                continue
            }
            if b == 0x22 || b == 0x27 { quote = b; i += 1; continue }
            if b == 0x28 { parenDepth += 1; i += 1; continue } // (
            if b == 0x29 { parenDepth = max(0, parenDepth - 1); i += 1; continue } // )
            if b == 0x5B { bracketDepth += 1; i += 1; continue } // [
            if b == 0x5D { bracketDepth = max(0, bracketDepth - 1); i += 1; continue } // ]
            if b == 0x2E, parenDepth == 0, bracketDepth == 0 { // .
                let start = i + 1
                var end = start
                while end < count, isClassIdentByte(bytes[end]) { end += 1 }
                if end > start {
                    // 未转义数字开头的 `.1` 不是合法类名，保守保留。
                    let first = bytes[start]
                    if first >= 0x30 && first <= 0x39 { return true }
                    let name = String(decoding: bytes[start..<end], as: UTF8.self)
                    if !usedClasses.contains(name) { return false }
                }
                i = end
                continue
            }
            i += 1
        }
        return true
    }

    private static func isClassIdentByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) // A-Z
            || (b >= 0x61 && b <= 0x7A) // a-z
            || (b >= 0x30 && b <= 0x39) // 0-9
            || b == 0x5F || b == 0x2D // _ -
            || b >= 0x80 // non-ASCII UTF-8
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
