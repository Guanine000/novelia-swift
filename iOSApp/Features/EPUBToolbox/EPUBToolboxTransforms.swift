// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ImageIO
#if canImport(NoveliaIOSCore)
import NoveliaIOSCore
#endif
import ReadiumZIPFoundation
import SwiftSoup
import UniformTypeIdentifiers

/// EPUB 工具箱专项变换器：图片压缩、样式与字体清洗、简繁转换、横竖排转换、Ruby 注音处理、注释标准化与正则目录重建。
enum EPUBToolboxTransforms {

    // MARK: - 1. 图片压缩（ImageIO）

    /// 使用系统 ImageIO 按最大边长与 JPEG 质量压缩图片；仅在压缩后体积严格变小时返回新字节与新 MIME 类型。
    static func compressImage(
        data: Data,
        mediaType: String,
        option: EPUBImageCompressionOption
    ) -> (data: Data, mediaType: String, savedBytes: Int64)? {
        guard option != .off else { return nil }
        let mt = mediaType.lowercased()
        // 跳过矢量图、GIF（可能含动画）与非常小的图标
        guard mt != "image/svg+xml", mt != "image/gif", data.count > 16 * 1024 else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // 若有多帧（动图 APNG / WebP 等），跳过避免丢帧
        if CGImageSourceGetCount(source) > 1 { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let hasAlpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false

        let cgImage: CGImage?
        let maxSide = max(width, height)
        if maxSide > option.maxPixelSize && option.maxPixelSize > 0 {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: option.maxPixelSize,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image = cgImage else { return nil }

        // 带透明通道的 PNG 若强转 JPEG 会失去透明底，保留 PNG 仅在缩图变小时采用；否则统一输出 JPEG
        let outputUTI: CFString
        let outputMediaType: String
        let destProps: [CFString: Any]
        if hasAlpha && mt == "image/png" {
            outputUTI = UTType.png.identifier as CFString
            outputMediaType = "image/png"
            destProps = [:]
        } else {
            outputUTI = UTType.jpeg.identifier as CFString
            outputMediaType = "image/jpeg"
            destProps = [kCGImageDestinationLossyCompressionQuality: option.jpegQuality]
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, outputUTI, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, destProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let compressed = mutableData as Data
        let saved = Int64(data.count) - Int64(compressed.count)
        guard saved > 512 else { return nil }
        return (compressed, outputMediaType, saved)
    }

    // MARK: - 2. CSS 清洗（移除 @font-face、强制样式、横竖排）

    static func removeFontFaceRules(in css: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"@font-face\s*\{[^}]*\}"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return css }
        let range = NSRange(location: 0, length: (css as NSString).length)
        return regex.stringByReplacingMatches(in: css, range: range, withTemplate: "")
    }

    /// 清理写死的字色、底色、字号、行高与字体族声明，使阅读器主题与字号设置能正常生效。
    static func cleanForcedStyles(in css: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<=[{;\s]|^)(?:color|background-color|font-size|line-height|font-family)\s*:[^;{}]+;?"#,
            options: [.caseInsensitive]
        ) else { return css }
        let range = NSRange(location: 0, length: (css as NSString).length)
        return regex.stringByReplacingMatches(in: css, range: range, withTemplate: "")
    }

    static func applyWritingDirection(_ direction: EPUBWritingDirectionTransform, toCSS css: String) -> String {
        guard direction != .keep else { return css }
        let targetValue = direction == .vertical ? "vertical-rl" : "horizontal-tb"
        guard let regex = try? NSRegularExpression(
            pattern: #"((?:-webkit-|-epub-)?writing-mode\s*:\s*)([^;{}]+)"#,
            options: [.caseInsensitive]
        ) else { return css }
        let ns = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return css }
        let mutable = NSMutableString(string: css)
        for match in matches.reversed() {
            let prefix = ns.substring(with: match.range(at: 1))
            mutable.replaceCharacters(in: match.range, with: "\(prefix)\(targetValue)")
        }
        return mutable as String
    }

    // MARK: - 3. XHTML 专项变换（Ruby / 注释 / 强制内联样式 / 横竖排）

    /// 处理文档中的所有 `<ruby>` 元素，返回处理数量。
    @discardableResult
    static func processRuby(in doc: Document, mode: EPUBRubyHandling) -> Int {
        guard mode != .keep, let rubies = try? doc.select("ruby").array(), !rubies.isEmpty else {
            return 0
        }
        var count = 0
        for ruby in rubies {
            let rtElements = (try? ruby.select("rt").array()) ?? []
            let annotation = rtElements.compactMap { try? $0.text() }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 移除 <rt> 和 <rp> 后取得底文
            for el in rtElements { _ = try? el.remove() }
            if let rps = try? ruby.select("rp").array() {
                for rp in rps { _ = try? rp.remove() }
            }
            let baseText = (try? ruby.text()) ?? ""
            let replacement: String
            switch mode {
            case .keep:
                continue
            case .removeAnnotations:
                replacement = baseText
            case .inlineParentheses:
                replacement = annotation.isEmpty ? baseText : "\(baseText)（\(annotation)）"
            }
            do {
                try ruby.replaceWith(TextNode(replacement, nil))
                count += 1
            } catch {
                // 忽略单个异常节点
            }
        }
        return count
    }

    /// 将多看/旧版常见脚注结构规范化为标准 EPUB 3 `epub:type="noteref"` 与 `<aside epub:type="footnote">`。
    @discardableResult
    static func standardizeFootnotes(in doc: Document) -> Int {
        var count = 0
        // 1) 标记注脚引用锚点
        let refSelectors = [
            "a.duokan-footnote",
            "a[class*=footnote]",
            "a[class*=noteref]",
            "a[href^=#fn]",
            "a[href^=#note]",
            "a[href^=#footnote]",
        ]
        var seenAnchors = Set<ObjectIdentifier>()
        for selector in refSelectors {
            guard let anchors = try? doc.select(selector).array() else { continue }
            for anchor in anchors {
                let oid = ObjectIdentifier(anchor)
                guard seenAnchors.insert(oid).inserted else { continue }
                let existing = ((try? anchor.attr("epub:type")) ?? "").lowercased()
                if !existing.contains("noteref") {
                    _ = try? anchor.attr("epub:type", existing.isEmpty ? "noteref" : "\(existing) noteref")
                    count += 1
                }
            }
        }

        // 2) 将多看注释条目 <li class="duokan-footnote-item" id="..."> 升级为标准 <aside epub:type="footnote" id="...">
        if let duokanItems = try? doc.select("li.duokan-footnote-item").array() {
            for item in duokanItems {
                let id = (try? item.attr("id")) ?? ""
                let innerHTML = (try? item.html()) ?? ""
                let aside = Element(Tag("aside"), "")
                if !id.isEmpty { _ = try? aside.attr("id", id) }
                _ = try? aside.attr("epub:type", "footnote")
                _ = try? aside.attr("class", "duokan-footnote-item")
                _ = try? aside.html(innerHTML)
                if (try? item.replaceWith(aside)) != nil {
                    count += 1
                }
            }
        }

        // 3) 兼容已存在的 <aside> 或 <div class="footnote"> 补齐 epub:type="footnote"
        if let footnoteBoxes = try? doc.select("aside[id], div.footnote[id], section.footnote[id]").array() {
            for box in footnoteBoxes {
                let existing = ((try? box.attr("epub:type")) ?? "").lowercased()
                let cls = ((try? box.attr("class")) ?? "").lowercased()
                let id = ((try? box.attr("id")) ?? "").lowercased()
                if !existing.contains("footnote") && (cls.contains("footnote") || id.hasPrefix("fn") || id.hasPrefix("note")) {
                    _ = try? box.attr("epub:type", existing.isEmpty ? "footnote" : "\(existing) footnote")
                    count += 1
                }
            }
        }
        return count
    }

    /// 清理元素内联 `style="..."` 中写死的字色/底色/字号/行高/字体族。
    @discardableResult
    static func cleanInlineForcedStyles(in doc: Document) -> Int {
        guard let styled = try? doc.select("[style]").array() else { return 0 }
        var count = 0
        for el in styled {
            guard let style = try? el.attr("style"), !style.isEmpty else { continue }
            let cleaned = cleanForcedStyles(in: style).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned != style {
                if cleaned.isEmpty {
                    _ = try? el.removeAttr("style")
                } else {
                    _ = try? el.attr("style", cleaned)
                }
                count += 1
            }
        }
        return count
    }

    /// 为 XHTML 文档注入统一横排/竖排 CSS 声明并更新内部 `<style>` / 内联 `writing-mode`。
    static func applyWritingDirection(_ direction: EPUBWritingDirectionTransform, toDoc doc: Document) {
        guard direction != .keep else { return }
        // 更新 <style> 块
        if let styleEls = try? doc.select("style").array() {
            for styleEl in styleEls {
                let css = styleEl.data()
                let updated = applyWritingDirection(direction, toCSS: css)
                if updated != css {
                    _ = try? styleEl.text("")
                    _ = try? styleEl.appendChild(DataNode(Array(updated.utf8), []))
                }
            }
        }
        // 更新内联 style 中的 writing-mode
        if let styled = try? doc.select("[style]").array() {
            for el in styled {
                guard let style = try? el.attr("style"),
                      style.range(of: "writing-mode", options: .caseInsensitive) != nil else { continue }
                let updated = applyWritingDirection(direction, toCSS: style)
                if updated != style { _ = try? el.attr("style", updated) }
            }
        }
        // 在 <head> 末尾追加统一覆盖规则，确保未写 CSS 的章节也生效
        if let head = try? doc.select("head").first() {
            let mode = direction == .vertical ? "vertical-rl" : "horizontal-tb"
            let rule = "html, body { writing-mode: \(mode); -webkit-writing-mode: \(mode); -epub-writing-mode: \(mode); }"
            let styleTag = Element(Tag("style"), "")
            _ = try? styleTag.attr("type", "text/css")
            _ = try? styleTag.appendChild(DataNode(Array(rule.utf8), []))
            _ = try? head.appendChild(styleTag)
        }
    }

    // MARK: - 4. 全书简繁转换（复用 ReadingTextProjection）

    static func projection(for option: EPUBChineseConversionOption) -> ReadingTextProjection? {
        switch option {
        case .none: return nil
        case .toSimplified:
            var p = ReadingTextProjection()
            p.chinese = .simplified
            return p
        case .toTraditional:
            var p = ReadingTextProjection()
            p.chinese = .traditional
            return p
        }
    }

    static func convertHTML(_ html: String, option: EPUBChineseConversionOption) -> String {
        guard let proj = projection(for: option) else { return html }
        return proj.applyHTML(html)
    }

    static func convertText(_ text: String, option: EPUBChineseConversionOption) -> String {
        guard let proj = projection(for: option) else { return text }
        return proj.apply(text)
    }

    // MARK: - 5. 按自定义正则重建目录

    /// 按用户输入的正则扫描全书 spine 章节的标题/段落，生成新目录树。
    static func rebuildTOC(url: URL, regexPattern: String) async throws -> [EPUBToolboxTOCNode] {
        let pattern = regexPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return [] }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw EPUBToolboxError.writeFailed("正则表达式语法无效：\(error.localizedDescription)")
        }

        guard let archive = try? await Archive(url: url, accessMode: .read) else {
            throw EPUBToolboxError.invalidArchive
        }
        let entries = (try? await archive.entries()) ?? []
        var entryByPath: [String: Entry] = [:]
        for entry in entries where entry.type == .file {
            let norm = EPUBToolboxPath.normalize(entry.path)
            if !norm.isEmpty { entryByPath[norm] = entry }
        }
        let opfPath: String?
        if let containerEntry = entryByPath["META-INF/container.xml"],
           let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: containerEntry, limit: 1024 * 1024),
           let xml = EPUBToolboxInspector.decodeText(data).text,
           let parsed = EPUBToolboxInspector.parseContainerOPFPath(xml: xml),
           entryByPath[parsed] != nil {
            opfPath = parsed
        } else {
            opfPath = entryByPath.keys.sorted().first(where: { $0.lowercased().hasSuffix(".opf") })
        }
        guard let opfPath,
              let opfEntry = entryByPath[opfPath],
              let opfData = try? await EPUBToolboxInspector.extractData(from: archive, entry: opfEntry, limit: EPUBToolboxInspector.maxTextEntryBytes),
              let opfXML = EPUBToolboxInspector.decodeText(opfData).text,
              let opf = EPUBToolboxInspector.parseOPF(xml: opfXML, opfPath: opfPath) else {
            throw EPUBToolboxError.missingOPF
        }

        let manifestByID = Dictionary(opf.manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var nodes: [EPUBToolboxTOCNode] = []
        var seen = Set<String>()

        for sp in opf.spine {
            guard let item = manifestByID[sp.idref],
                  item.isXHTML,
                  let entry = entryByPath[item.path],
                  let data = try? await EPUBToolboxInspector.extractData(from: archive, entry: entry, limit: EPUBToolboxInspector.maxTextEntryBytes),
                  let html = EPUBToolboxInspector.decodeText(data).text,
                  let doc = try? SwiftSoup.parse(html) else { continue }

            let candidates = (try? doc.select("h1, h2, h3, h4, p, div").array()) ?? []
            for el in candidates.prefix(40) {
                // 只看直接文本较短的段落或标题，避免把整段正文匹配进来
                guard let raw = try? el.text() else { continue }
                let text = raw.replacingOccurrences(of: "[\\s　]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 100 else { continue }
                let nsRange = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, range: nsRange) != nil {
                    let key = "\(item.path)|\(text)"
                    if seen.insert(key).inserted {
                        nodes.append(EPUBToolboxTOCNode(title: text, path: item.path, fragment: "", children: []))
                    }
                    break
                }
            }
        }
        return nodes
    }
}
