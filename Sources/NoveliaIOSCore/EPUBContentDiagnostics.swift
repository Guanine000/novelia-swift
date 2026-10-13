import Foundation

/// Static observations of the book's original documents; does not emulate WebKit layout.
struct EPUBContentDiagnostics: Sendable {
    private(set) var scannedDocuments = 0
    private(set) var failedDocuments = 0
    private(set) var scripts = 0
    private(set) var mediaQueries = 0
    private(set) var flexGrid = 0
    private(set) var tableLayouts = 0
    private(set) var opacity = 0
    private(set) var textShadows = 0
    private(set) var svg = 0
    private(set) var remoteReferences = 0

    mutating func recordFailure() { failedDocuments += 1 }

    mutating func inspect(_ document: String, isCSS: Bool) {
        scannedDocuments += 1
        var text = document
        if isCSS {
            text = Self.replacing(#"/\*[\s\S]*?\*/"#, in: text)
        } else {
            text = Self.replacing(#"<!--[\s\S]*?-->"#, in: text)
            scripts += Self.count(#"<script\b"#, in: text)
            svg += Self.count(#"<svg\b"#, in: text)
            remoteReferences += Self.count(#"\b(?:src|href)\s*=\s*["'](?:https?:)?//"#, in: text)
            text = Self.replacing(#"<script\b[^>]*>[\s\S]*?</script\s*>"#, in: text)
            let styles = Self.captures(#"<style\b[^>]*>([\s\S]*?)</style\s*>"#, group: 1, in: text)
                + Self.captures(#"\bstyle\s*=\s*([\"'])([\s\S]*?)\1"#, group: 2, in: text)
            text = styles.joined(separator: "\n")
            text = Self.replacing(#"/\*[\s\S]*?\*/"#, in: text)
        }
        mediaQueries += Self.count(#"@media\b"#, in: text)
        flexGrid += Self.count(#"\bdisplay\s*:\s*(?:inline-)?(?:flex|grid)\b"#, in: text)
        tableLayouts += Self.count(#"\bdisplay\s*:\s*(?:table|table-cell)\b|\bvertical-align\s*:\s*middle\b"#, in: text)
        opacity += Self.count(#"\bopacity\s*:"#, in: text)
        textShadows += Self.count(#"\btext-shadow\s*:"#, in: text)
        remoteReferences += Self.count(#"\burl\(\s*["']?(?:https?:)?//"#, in: text)
    }

    var messages: [String] {
        var result: [String] = []
        if failedDocuments > 0 { result.append("有 \(failedDocuments) 份 HTML/CSS 文档未能读取，以下统计不包含这些文档。") }
        if scripts > 0 { result.append("本书包含 \(scripts) 处 script 元素。静态扫描不执行书内脚本，也不能据此确认依赖脚本的交互内容可用。") }
        if mediaQueries > 0 { result.append("本书包含 \(mediaQueries) 个 @media 规则。Readium 交由 WebKit 按屏幕与显示条件求值。") }
        if flexGrid > 0 { result.append("本书包含 \(flexGrid) 处 Flex/Grid 布局声明。Readium 使用 WebKit 渲染，不进行原分页引擎的块布局降级。") }
        if tableLayouts > 0 { result.append("本书包含 \(tableLayouts) 处表格化布局或垂直居中声明。Readium 保留原始声明，实际显示随内容和屏幕尺寸变化。") }
        if opacity > 0 { result.append("本书包含 \(opacity) 处 opacity 透明度声明。Readium 保留原始 CSS，不转换为文字颜色。") }
        if textShadows > 0 { result.append("本书包含 \(textShadows) 处 text-shadow 文字阴影声明。Readium 保留原始阴影，不以阴影颜色替换文字颜色。") }
        if svg > 0 { result.append("HTML 中包含 \(svg) 处内嵌 SVG。Readium 使用 WebKit 显示；统计不包含独立 SVG 文件。") }
        if remoteReferences > 0 { result.append("发现 \(remoteReferences) 处 HTTP/HTTPS 或相对协议的资源／链接引用，包含普通外部链接；离线时外部资源可能不可用。扫描不会访问这些地址。") }
        return result
    }

    private static func captures(_ pattern: String, group: Int, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func replacing(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
