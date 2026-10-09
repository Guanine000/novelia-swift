import Foundation
import ReadiumZIPFoundation
import UIKit

// MARK: - 样例 EPUB 生成器（可复现的最小验证样本）
//
// 用途：在没有用户真实问题 EPUB 时提供可复现的分页验证材料。
// 内容覆盖：三个 XHTML 章节、外部 CSS、一张生成图片、EPUB3 注脚（noteref/aside）、
// 足够篇幅的 CJK 正文以产生多页分页。
// 注意：这只解决"可复现"，不能替代用户真实 EPUB 的真机验收。

enum PrototypeSampleBook {
    static var sampleURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("prototype-sample.epub")
    }

    /// 返回样例 EPUB 路径；不存在则生成。
    static func sampleURL() async throws -> URL {
        let url = sampleURL
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await write(to: url)
        return url
    }

    static func write(to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let archive = try await Archive(url: destination, accessMode: .create)

        func addEntry(_ path: String, data: Data, compress: Bool = true) async throws {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await archive.addEntry(
                with: path,
                fileURL: temporary,
                compressionMethod: compress ? .deflate : .none
            )
        }

        // mimetype 必须是第一个未压缩条目。
        try await addEntry("mimetype", data: Data("application/epub+zip".utf8), compress: false)
        try await addEntry("META-INF/container.xml", data: Data(containerXML.utf8))
        try await addEntry("OEBPS/content.opf", data: Data(opfXML.utf8))
        try await addEntry("OEBPS/nav.xhtml", data: Data(navXML.utf8))
        try await addEntry("OEBPS/style.css", data: Data(styleCSS.utf8))
        try await addEntry("OEBPS/images/figure.png", data: makeFigurePNG())
        for (index, chapter) in chapters.enumerated() {
            try await addEntry("OEBPS/chapter\(index + 1).xhtml", data: Data(chapter.utf8))
        }
    }

    // MARK: 内容

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static let opfXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">urn:uuid:prototype-sample-0001</dc:identifier>
        <dc:title>排版原型样例书</dc:title>
        <dc:creator>Novelia 原型</dc:creator>
        <dc:language>zh</dc:language>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="css" href="style.css" media-type="text/css"/>
        <item id="figure" href="images/figure.png" media-type="image/png"/>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="ch1"/>
        <itemref idref="ch2"/>
        <itemref idref="ch3"/>
      </spine>
    </package>
    """

    private static let navXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>目录</title></head>
      <body>
        <nav epub:type="toc">
          <ol>
            <li><a href="chapter1.xhtml">第一章 起伏的山谷</a></li>
            <li><a href="chapter2.xhtml">第二章 河流与灯火</a></li>
            <li><a href="chapter3.xhtml">第三章 归途</a></li>
          </ol>
        </nav>
      </body>
    </html>
    """

    private static let styleCSS = """
    body { margin: 0; font-family: serif; line-height: 1.7; }
    p { margin: 0 0 0.6em 0; text-indent: 2em; }
    figure { margin: 1em 0; text-align: center; }
    img { max-width: 80%; height: auto; }
    .noteref { text-decoration: none; color: #35618f; }
    """

    private static func paragraph(_ text: String) -> String {
        "<p>\(text)</p>"
    }

    private static func repeatedParagraphs(seed: String, count: Int) -> String {
        (0..<count).map { index in
            paragraph("\(seed)第 \(index + 1) 段。山谷里的风从北面吹来，掠过起伏的草浪，把远处溪水的声音送到耳边。天色一点点暗下去，最后一缕光落在山脊上，像谁轻轻搁下的一支笔。夜里虫声四起，灯火在窗纸上摇动，读书的人抬起头，看见月亮已经爬过了屋檐。")
        }
        .joined(separator: "\n")
    }

    private static var chapters: [String] {
        let chapter1 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>第一章 起伏的山谷</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body>
            <h1>第一章 起伏的山谷</h1>
            \(repeatedParagraphs(seed: "清晨的雾还没有散，", count: 14))
            <figure><img src="images/figure.png" alt="山谷示意图"/></figure>
            \(repeatedParagraphs(seed: "太阳升起来之后，", count: 14))
            <p>村里的老人常说，山谷里藏着一条看不见的河<sup><a class="noteref" epub:type="noteref" href="#note1">[1]</a></sup>，它只在雨季出现，把两座山连成一片水面。</p>
            <aside id="note1" epub:type="footnote">传说源自民国年间的县志卷三，作者未能考证原碑，仅记录口述。</aside>
            \(repeatedParagraphs(seed: "雨季来的时候，", count: 12))
          </body>
        </html>
        """
        let chapter2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>第二章 河流与灯火</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body>
            <h1>第二章 河流与灯火</h1>
            \(repeatedParagraphs(seed: "河面上的灯是节日的信号，", count: 30))
            <p>第二处注脚用来验证浮窗<sup><a class="noteref" epub:type="noteref" href="#note2">[2]</a></sup>。</p>
            <aside id="note2" epub:type="footnote">此处正文与注脚分属不同段落，用于检查注脚定位是否准确。</aside>
            \(repeatedParagraphs(seed: "夜色渐深，", count: 24))
          </body>
        </html>
        """
        let chapter3 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <head><title>第三章 归途</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
          <body>
            <h1>第三章 归途</h1>
            \(repeatedParagraphs(seed: "回程的路比来时更短，", count: 26))
          </body>
        </html>
        """
        return [chapter1, chapter2, chapter3]
    }

    /// 生成一张简单的渐变示意图 PNG。
    private static func makeFigurePNG() -> Data {
        let size = CGSize(width: 420, height: 260)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let colors = [UIColor(red: 0.42, green: 0.55, blue: 0.72, alpha: 1).cgColor,
                          UIColor(red: 0.92, green: 0.86, blue: 0.72, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(
                gradient, start: .zero,
                end: CGPoint(x: size.width, y: size.height), options: [])
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            ("山谷示意图" as NSString).draw(
                in: CGRect(x: 0, y: size.height / 2 - 16, width: size.width, height: 32),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraphStyle,
                ])
        }
        return image.pngData() ?? Data()
    }
}
