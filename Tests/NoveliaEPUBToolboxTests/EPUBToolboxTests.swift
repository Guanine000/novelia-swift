// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ReadiumZIPFoundation
import XCTest
@testable import NoveliaEPUB
@testable import NoveliaEPUBToolbox

final class EPUBToolboxTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBToolboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - 辅助构造测试 EPUB

    private func makeArchive(name: String, entries: [(path: String, data: Data, compressed: Bool)]) async throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        guard let archive = try? await Archive(url: url, accessMode: .create) else {
            XCTFail("无法创建测试 ZIP")
            throw EPUBToolboxError.invalidArchive
        }
        for entry in entries {
            try await archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: entry.compressed ? .deflate : .none
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, entry.data.count)
                return entry.data.subdata(in: start..<end)
            }
        }
        return url
    }

    /// 1x1 最小合法 PNG 字节，供封面与插图测试使用。
    private var tinyPNG: Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
    }

    // MARK: - 1. 体检 + 全套标准化修复 + EPUBContainer 端到端验证

    func testInspectAndFullStandardizationAndReaderCompatibility() async throws {
        // 构造一本包含多种典型野生问题的 EPUB 3：
        // - mimetype 缺失
        // - 非 Sigil 目录（根目录 content.opf、chapters/ch1.html、css/main.css、img/pic.png）
        // - OPF 存在死链（missing.xhtml）、未注册文件（img/unused_orphan.png）、__MACOSX 垃圾文件
        // - 缺少 nav 与 ncx 目录
        // - 存在封面图 img/cover.png 但未在 OPF 中声明封面
        // - ch1.html 存在未闭合标签与非法实体（非良构 XHTML）
        // - 存在已注册但未被引用的冗余图片 img/unused_manifest.png 和冗余样式 css/unused.css
        let containerXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opfXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>野生测试书</dc:title>
            <dc:creator>测试作者</dc:creator>
            <dc:language>zh-CN</dc:language>
            <dc:identifier id="uid">urn:uuid:11111111-2222-3333-4444-555555555555</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="chapters/ch1.html" media-type="application/xhtml+xml"/>
            <item id="dead" href="chapters/missing.xhtml" media-type="application/xhtml+xml"/>
            <item id="css1" href="css/main.css" media-type="text/css"/>
            <item id="css_unused" href="css/unused.css" media-type="text/css"/>
            <item id="img_cover" href="img/cover.png" media-type="image/png"/>
            <item id="img_used" href="img/pic.png" media-type="image/png"/>
            <item id="img_bg" href="img/bg.png" media-type="image/png"/>
            <item id="img_unused" href="img/unused_manifest.png" media-type="image/png"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="dead"/>
          </spine>
        </package>
        """
        let badHTML = """
        <html>
        <head>
          <title>第一章 启程</title>
          <link rel="stylesheet" href="../css/main.css">
        </head>
        <body>
          <h1>第一章 启程</h1>
          <p>这是第一段正文 & 未转义符号<br>换行后没有闭合段落
          <img src="../img/pic.png">
        </body>
        </html>
        """
        let css = """
        body { background-image: url("../img/bg.png"); color: #222; }
        """

        let sourceURL = try await makeArchive(name: "messy.epub", entries: [
            ("META-INF/container.xml", Data(containerXML.utf8), true),
            ("content.opf", Data(opfXML.utf8), true),
            ("chapters/ch1.html", Data(badHTML.utf8), true),
            ("css/main.css", Data(css.utf8), true),
            ("css/unused.css", Data("p { color: red; }".utf8), true),
            ("img/cover.png", tinyPNG, false),
            ("img/pic.png", tinyPNG, false),
            ("img/bg.png", tinyPNG, false),
            ("img/unused_manifest.png", tinyPNG, false),
            ("img/unused_orphan.png", tinyPNG, false),
            ("__MACOSX/.DS_Store", Data([0x00, 0x01]), true),
        ])

        // 1) 轻量体检：快速检出结构、OPF、目录、封面问题，不解压正文
        let lightReport = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .lightweight)
        XCTAssertTrue(lightReport.hasActionableIssues)
        XCTAssertTrue(lightReport.issues.contains(where: { $0.category == .structure }))
        XCTAssertTrue(lightReport.issues.contains(where: { $0.category == .opf }))
        XCTAssertTrue(lightReport.issues.contains(where: { $0.category == .toc }))
        XCTAssertTrue(lightReport.issues.contains(where: { $0.category == .cover }))

        // 2) 深度体检：额外检出畸形 XHTML 与冗余资源
        let deepReport = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .deep)
        XCTAssertTrue(deepReport.issues.contains(where: { $0.category == .xhtml }))
        XCTAssertGreaterThanOrEqual(deepReport.unusedResourceCount, 3)

        // 3) 执行完整四项处理
        let outputURL = tempDir.appendingPathComponent("cleaned.epub")
        let result = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outputURL, options: .all)
        XCTAssertGreaterThan(result.relocatedPathsCount, 0)
        XCTAssertEqual(result.mendedXHTMLCount, 1)
        XCTAssertEqual(result.removedDeadManifestCount, 1)
        XCTAssertTrue(result.repairedTOC)
        XCTAssertTrue(result.repairedCover)
        XCTAssertGreaterThanOrEqual(result.removedUnusedCount, 4) // unused.css + unused_manifest.png + unused_orphan.png + .DS_Store

        // 4) 校验输出 ZIP 结构符合 Sigil Norm
        guard let outArchive = try? await Archive(url: outputURL, accessMode: .read) else {
            return XCTFail("输出 EPUB 无法以 ZIP 打开")
        }
        let orderedEntries = try await outArchive.entries()
        XCTAssertEqual(orderedEntries.first?.path, "mimetype")
        XCTAssertEqual(orderedEntries.first?.isCompressed, false)

        let entryPaths = Set(orderedEntries.map(\.path))
        XCTAssertTrue(entryPaths.contains("META-INF/container.xml"))
        XCTAssertTrue(entryPaths.contains("OEBPS/content.opf"))
        XCTAssertTrue(entryPaths.contains("OEBPS/toc.ncx"))
        XCTAssertTrue(entryPaths.contains("OEBPS/Text/ch1.xhtml"))
        XCTAssertTrue(entryPaths.contains("OEBPS/Styles/main.css"))
        XCTAssertTrue(entryPaths.contains("OEBPS/Images/cover.png"))
        XCTAssertTrue(entryPaths.contains("OEBPS/Images/pic.png"))
        XCTAssertTrue(entryPaths.contains("OEBPS/Images/bg.png"))
        XCTAssertFalse(entryPaths.contains("OEBPS/Styles/unused.css"))
        XCTAssertFalse(entryPaths.contains("OEBPS/Images/unused_manifest.png"))
        XCTAssertFalse(entryPaths.contains("OEBPS/Images/unused_orphan.png"))
        XCTAssertFalse(entryPaths.contains("__MACOSX/.DS_Store"))

        // 校验 XHTML 和 CSS 相对路径已重写且 XML 良构
        let ch1Optional = try await outArchive.get("OEBPS/Text/ch1.xhtml")
        let ch1Entry = try XCTUnwrap(ch1Optional)
        let ch1Data = try await EPUBToolboxInspector.extractData(from: outArchive, entry: ch1Entry, limit: 1024 * 1024)
        let ch1Text = try XCTUnwrap(String(data: ch1Data, encoding: .utf8))
        XCTAssertTrue(EPUBToolboxInspector.isWellFormedXML(data: ch1Data))
        XCTAssertTrue(ch1Text.contains("../Styles/main.css"))
        XCTAssertTrue(ch1Text.contains("../Images/pic.png"))

        let cssOptional = try await outArchive.get("OEBPS/Styles/main.css")
        let cssEntry = try XCTUnwrap(cssOptional)
        let cssData = try await EPUBToolboxInspector.extractData(from: outArchive, entry: cssEntry, limit: 1024 * 1024)
        let cssText = try XCTUnwrap(String(data: cssData, encoding: .utf8))
        XCTAssertTrue(cssText.contains("../Images/bg.png"))

        // 5) 对处理后的 EPUB 再跑一次深度体检：不应再有可修复问题
        let afterReport = try await EPUBToolboxInspector.inspect(url: outputURL, mode: .deep)
        XCTAssertFalse(afterReport.hasActionableIssues, "修复后不应再有可修复问题：\(afterReport.issues)")

        // 6) 用项目真实 EPUBContainer 打开输出 EPUB 验证端到端阅读兼容
        let container = try await EPUBContainer.open(fileURL: outputURL)
        let spine = await container.spine
        let toc = await container.toc
        XCTAssertEqual(spine.count, 1)
        XCTAssertEqual(toc.count, 1)
        XCTAssertEqual(toc.first?.title, "第一章 启程")
    }

    // MARK: - 2. DRM 保护拒绝 & 字体混淆放行

    func testDRMProtectedEPUBIsRejected() async throws {
        let drmXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/Text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let sourceURL = try await makeArchive(name: "drm.epub", entries: [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/encryption.xml", Data(drmXML.utf8), true),
        ])

        let report = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .lightweight)
        XCTAssertTrue(report.isDRMProtected)
        XCTAssertFalse(report.hasActionableIssues)

        let outURL = tempDir.appendingPathComponent("drm-out.epub")
        do {
            _ = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outURL, options: .all)
            XCTFail("应当拒绝 DRM 保护的 EPUB")
        } catch let error as EPUBToolboxError {
            XCTAssertEqual(error, .drmProtected)
        }
    }

    func testFontObfuscationIsAllowedAndURIRewritten() async throws {
        let encXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="fonts/custom.otf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        let containerXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opfXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>字体混淆测试</dc:title>
            <dc:language>zh</dc:language>
            <dc:identifier id="uid">urn:uuid:aaaa</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="main.css" media-type="text/css"/>
            <item id="font1" href="fonts/custom.otf" media-type="font/otf"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let ch1 = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><link rel="stylesheet" href="main.css"/></head><body><h1>正文</h1></body></html>
        """
        let css = #"@font-face { font-family: "Test"; src: url("fonts/custom.otf"); }"#

        let sourceURL = try await makeArchive(name: "obfuscated.epub", entries: [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), true),
            ("META-INF/encryption.xml", Data(encXML.utf8), true),
            ("content.opf", Data(opfXML.utf8), true),
            ("ch1.xhtml", Data(ch1.utf8), true),
            ("main.css", Data(css.utf8), true),
            ("fonts/custom.otf", Data([0x4F, 0x54, 0x54, 0x4F]), true),
        ])

        let report = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .lightweight)
        XCTAssertFalse(report.isDRMProtected)

        let outURL = tempDir.appendingPathComponent("obfuscated-out.epub")
        _ = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outURL, options: .all)

        let outArchiveOptional = try? await Archive(url: outURL, accessMode: .read)
        let outArchive = try XCTUnwrap(outArchiveOptional)
        let outEncOptional = try await outArchive.get("META-INF/encryption.xml")
        let outEncEntry = try XCTUnwrap(outEncOptional)
        let outEncData = try await EPUBToolboxInspector.extractData(from: outArchive, entry: outEncEntry, limit: 1024 * 1024)
        let outEncText = try XCTUnwrap(String(data: outEncData, encoding: .utf8))
        XCTAssertTrue(outEncText.contains("OEBPS/Fonts/custom.otf"))
    }

    // MARK: - 3. 独立开关隔离（仅清理冗余资源，不改目录结构）

    func testOnlyRemoveUnusedResourcesPreservesOriginalLayout() async throws {
        let containerXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="book/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opfXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>仅清理测试</dc:title>
            <dc:language>zh</dc:language>
            <dc:identifier id="uid">urn:uuid:bbbb</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="unused" href="extra.png" media-type="image/png"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let ch1 = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hello</p></body></html>
        """

        let sourceURL = try await makeArchive(name: "keep-layout.epub", entries: [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), true),
            ("book/package.opf", Data(opfXML.utf8), true),
            ("book/ch1.xhtml", Data(ch1.utf8), true),
            ("book/extra.png", tinyPNG, false),
        ])

        let options = EPUBToolboxOptions(
            standardizeStructure: false,
            mendXHTML: false,
            repairOPFTOCCover: false,
            removeUnusedResources: true
        )
        let outURL = tempDir.appendingPathComponent("keep-layout-out.epub")
        let result = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outURL, options: options)

        XCTAssertEqual(result.relocatedPathsCount, 0)
        XCTAssertEqual(result.removedUnusedCount, 1)

        let outArchiveOptional = try? await Archive(url: outURL, accessMode: .read)
        let outArchive = try XCTUnwrap(outArchiveOptional)
        let entries = try await outArchive.entries()
        let paths = Set(entries.map(\.path))
        XCTAssertTrue(paths.contains("book/package.opf"))
        XCTAssertTrue(paths.contains("book/ch1.xhtml"))
        XCTAssertFalse(paths.contains("book/extra.png"))
    }

    // MARK: - 4. 外部真实 EPUB 样本诊断（需设置环境变量 EPUB_TOOLBOX_TEST_FILE）

    func testExternalRealEPUBSampleIfProvided() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["EPUB_TOOLBOX_TEST_FILE"],
              !rawPath.isEmpty else {
            throw XCTSkip("未提供 EPUB_TOOLBOX_TEST_FILE，跳过外部真实样本测试。")
        }
        let sourceURL = URL(fileURLWithPath: rawPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "找不到测试 EPUB")

        let t0 = Date()
        let light = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .lightweight)
        let lightMs = Int(Date().timeIntervalSince(t0) * 1000)

        let t1 = Date()
        let deep = try await EPUBToolboxInspector.inspect(url: sourceURL, mode: .deep)
        let deepMs = Int(Date().timeIntervalSince(t1) * 1000)

        print("=== REAL EPUB LIGHTWEIGHT (\(lightMs)ms) ===")
        print("version=\(light.epubVersion) spine=\(light.spineCount) entries=\(light.entryCount) drm=\(light.isDRMProtected) fxl=\(light.isFixedLayout) actionable=\(light.hasActionableIssues)")
        for issue in light.issues {
            print("  [\(issue.severity.title)][\(issue.category.title)] \(issue.title): \(issue.detail) paths=\(issue.affectedPaths)")
        }

        print("=== REAL EPUB DEEP (\(deepMs)ms) ===")
        print("hasScripts=\(deep.hasScripts) unusedCount=\(deep.unusedResourceCount) unusedBytes=\(deep.unusedResourceBytes)")
        for issue in deep.issues {
            print("  [\(issue.severity.title)][\(issue.category.title)] \(issue.title): \(issue.detail) paths=\(issue.affectedPaths)")
        }

        let outURL = tempDir.appendingPathComponent("real-processed.epub")
        let t2 = Date()
        let result = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outURL, options: .all)
        let procMs = Int(Date().timeIntervalSince(t2) * 1000)

        print("=== REAL EPUB PROCESS (\(procMs)ms) ===")
        print("size: \(result.originalSizeBytes) -> \(result.outputSizeBytes)")
        print("relocated=\(result.relocatedPathsCount) mendedXHTML=\(result.mendedXHTMLCount) deadManifest=\(result.removedDeadManifestCount) registeredOrphan=\(result.registeredOrphanCount) repairedTOC=\(result.repairedTOC) repairedCover=\(result.repairedCover) removedUnused=\(result.removedUnusedCount)(\(result.removedUnusedBytes)B)")

        let after = try await EPUBToolboxInspector.inspect(url: outURL, mode: .deep)
        print("=== REAL EPUB AFTER DEEP ===")
        print("actionable=\(after.hasActionableIssues) issues=\(after.issues.count)")
        for issue in after.issues {
            print("  [\(issue.severity.title)][\(issue.category.title)] \(issue.title): \(issue.detail) paths=\(issue.affectedPaths)")
        }

        let beforeContainer = try await EPUBContainer.open(fileURL: sourceURL)
        let afterContainer = try await EPUBContainer.open(fileURL: outURL)
        let beforeSpine = await beforeContainer.spine
        let afterSpine = await afterContainer.spine
        let beforeTOC = await beforeContainer.toc
        let afterTOC = await afterContainer.toc
        let beforeDiag = await beforeContainer.tocDiagnostic ?? "none"
        let afterDiag = await afterContainer.tocDiagnostic ?? "none"
        print("=== CONTAINER COMPARE ===")
        print("spine: \(beforeSpine.count) -> \(afterSpine.count)")
        print("toc: \(beforeTOC.count) -> \(afterTOC.count)")
        print("tocDiag: \(beforeDiag) -> \(afterDiag)")
        XCTAssertFalse(after.hasActionableIssues, "处理后不应再残留可修复问题")
        XCTAssertEqual(afterSpine.count, beforeSpine.count)
    }

    // MARK: - 5. 高级变换：字体/样式清洗、简繁、横竖排、EPUB 2→3、Ruby、注释、元数据覆盖

    func testAdvancedSingleBookTransforms() async throws {
        let containerXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opfXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>原始繁體標題</dc:title>
            <dc:creator>舊作者</dc:creator>
            <dc:language>zh-TW</dc:language>
            <dc:identifier id="uid">urn:uuid:adv-1</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css1" href="Styles/style.css" media-type="text/css"/>
            <item id="font1" href="Fonts/embed.ttf" media-type="font/ttf"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let css = """
        @font-face { font-family: "EmbedFont"; src: url("../Fonts/embed.ttf"); }
        body { color: #000000; background-color: #ffffff; font-size: 14px; writing-mode: vertical-rl; }
        """
        let ch1 = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><link rel="stylesheet" href="../Styles/style.css"/></head>
        <body>
          <h1>第一章 測試</h1>
          <p style="color: black; font-size: 12pt;">這裡有<ruby>漢字<rt>かんじ</rt></ruby>和註釋<a class="duokan-footnote" href="#fn1">[1]</a>。</p>
          <ol class="duokan-footnote-content"><li class="duokan-footnote-item" id="fn1">註釋說明</li></ol>
        </body>
        </html>
        """

        let sourceURL = try await makeArchive(name: "advanced-src.epub", entries: [
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(containerXML.utf8), true),
            ("OEBPS/content.opf", Data(opfXML.utf8), true),
            ("OEBPS/Text/ch1.xhtml", Data(ch1.utf8), true),
            ("OEBPS/Styles/style.css", Data(css.utf8), true),
            ("OEBPS/Fonts/embed.ttf", Data(repeating: 0x41, count: 4096), true),
        ])

        var options = EPUBToolboxOptions.all
        options.removeEmbeddedFonts = true
        options.cleanForcedStyles = true
        options.chineseConversion = .toSimplified
        options.writingDirection = .horizontal
        options.upgradeToEPUB3 = true
        options.rubyHandling = .inlineParentheses
        options.standardizeFootnotes = true
        options.metadataOverride = EPUBMetadataOverride(
            title: "新标题",
            author: "新作者",
            language: "zh-Hans",
            description: "这是测试简介",
            coverImageData: tinyPNG,
            coverMediaType: "image/png"
        )

        let outURL = tempDir.appendingPathComponent("advanced-out.epub")
        let result = try await EPUBToolboxProcessor.process(source: sourceURL, destination: outURL, options: options)

        XCTAssertEqual(result.removedFontsCount, 1)
        XCTAssertGreaterThan(result.cleanedStyleCount, 0)
        XCTAssertTrue(result.convertedChinese)
        XCTAssertTrue(result.convertedWritingDirection)
        XCTAssertTrue(result.upgradedToEPUB3)
        XCTAssertEqual(result.processedRubyCount, 1)
        XCTAssertGreaterThanOrEqual(result.standardizedFootnotesCount, 2)
        XCTAssertTrue(result.updatedMetadata)

        let outArchiveOptional = try? await Archive(url: outURL, accessMode: .read)
        let outArchive = try XCTUnwrap(outArchiveOptional)
        let paths = Set((try await outArchive.entries()).map(\.path))
        XCTAssertFalse(paths.contains("OEBPS/Fonts/embed.ttf"))
        XCTAssertTrue(paths.contains("OEBPS/Text/nav.xhtml"))

        let outCh1Optional = try await outArchive.get("OEBPS/Text/ch1.xhtml")
        let outCh1Data = try await EPUBToolboxInspector.extractData(from: outArchive, entry: try XCTUnwrap(outCh1Optional), limit: 1024 * 1024)
        let outCh1 = try XCTUnwrap(String(data: outCh1Data, encoding: .utf8))
        XCTAssertTrue(outCh1.contains("汉字（かんじ）"))
        XCTAssertTrue(outCh1.contains(#"epub:type="noteref""#))
        XCTAssertTrue(outCh1.contains(#"epub:type="footnote""#))
        XCTAssertTrue(outCh1.contains("horizontal-tb"))
        XCTAssertFalse(outCh1.contains("font-size: 12pt"))

        let outCSSOptional = try await outArchive.get("OEBPS/Styles/style.css")
        let outCSSData = try await EPUBToolboxInspector.extractData(from: outArchive, entry: try XCTUnwrap(outCSSOptional), limit: 1024 * 1024)
        let outCSS = try XCTUnwrap(String(data: outCSSData, encoding: .utf8))
        XCTAssertFalse(outCSS.contains("@font-face"))
        XCTAssertFalse(outCSS.contains("background-color"))
        XCTAssertTrue(outCSS.contains("horizontal-tb"))

        let report = try await EPUBToolboxInspector.inspect(url: outURL, mode: .deep)
        XCTAssertEqual(report.epubVersion, "3.0")
        XCTAssertEqual(report.title, "新标题")
        XCTAssertEqual(report.author, "新作者")
    }

    // MARK: - 6. 合并多卷、拆分合集、导出 TXT、内部文件浏览器与正则重建目录

    func testMergeSplitExportTXTAndBrowser() async throws {
        func makeSimpleBook(name: String, title: String, chapterTitle: String, body: String) async throws -> URL {
            let container = """
            <?xml version="1.0" encoding="utf-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
            let opf = """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:language>zh-CN</dc:language>
                <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
              </metadata>
              <manifest>
                <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="nav" href="Text/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """
            let nav = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">\(chapterTitle)</a></li></ol></nav></body>
            </html>
            """
            let ch = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>\(chapterTitle)</h1><p>\(body)</p></body></html>
            """
            return try await makeArchive(name: name, entries: [
                ("mimetype", Data("application/epub+zip".utf8), false),
                ("META-INF/container.xml", Data(container.utf8), true),
                ("OEBPS/content.opf", Data(opf.utf8), true),
                ("OEBPS/Text/nav.xhtml", Data(nav.utf8), true),
                ("OEBPS/Text/ch1.xhtml", Data(ch.utf8), true),
            ])
        }

        let vol1 = try await makeSimpleBook(name: "vol1.epub", title: "第一卷", chapterTitle: "第一章 起点", body: "第一卷正文内容")
        let vol2 = try await makeSimpleBook(name: "vol2.epub", title: "第二卷", chapterTitle: "第二章 旅途", body: "第二卷正文内容")

        // 1) 合并两卷
        let mergedURL = tempDir.appendingPathComponent("merged.epub")
        let mergeResult = try await EPUBToolboxMerger.merge(
            volumes: [.init(title: "第一卷", url: vol1), .init(title: "第二卷", url: vol2)],
            title: "合集书",
            author: "作者A",
            destination: mergedURL
        )
        XCTAssertEqual(mergeResult.volumeCount, 2)
        XCTAssertEqual(mergeResult.totalSpineCount, 2)

        // 2) 内部文件浏览器与文本预览
        let entries = try await EPUBArchiveBrowser.listEntries(url: mergedURL)
        XCTAssertTrue(entries.contains(where: { $0.path == "OEBPS/content.opf" && $0.isTextPreviewable }))
        let opfPreview = try await EPUBArchiveBrowser.readTextPreview(url: mergedURL, entryPath: "OEBPS/content.opf")
        XCTAssertTrue(opfPreview.contains("合集书"))

        // 3) 正则重建目录
        let rebuiltTOC = try await EPUBToolboxTransforms.rebuildTOC(url: mergedURL, regexPattern: #"^第[一二]章"#)
        XCTAssertEqual(rebuiltTOC.count, 2)

        // 4) 导出为 TXT
        let txtURL = tempDir.appendingPathComponent("merged.txt")
        let txtResult = try await EPUBToolboxTXTExporter.exportToTXT(source: mergedURL, destination: txtURL)
        XCTAssertEqual(txtResult.chapterCount, 2)
        let txtContent = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(txtContent.contains("第一卷正文内容"))
        XCTAssertTrue(txtContent.contains("第二卷正文内容"))

        // 5) 拆分合集
        let proposed = try await EPUBToolboxSplitter.proposeGroups(url: mergedURL)
        XCTAssertEqual(proposed.count, 2)
        let splitDir = tempDir.appendingPathComponent("split-out", isDirectory: true)
        let splitResults = try await EPUBToolboxSplitter.split(source: mergedURL, groups: proposed, outputDirectory: splitDir)
        XCTAssertEqual(splitResults.count, 2)
        let splitContainer = try await EPUBContainer.open(fileURL: splitResults[0].outputURL)
        let splitSpine = await splitContainer.spine
        XCTAssertEqual(splitSpine.count, 1)
    }
}
