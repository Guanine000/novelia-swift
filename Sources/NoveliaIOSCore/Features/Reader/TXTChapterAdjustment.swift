// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 边界采用解码、换行规范化后原文的 UTF-16 坐标，不使用排版页码或标题查找。
struct TXTChapterBoundary: Codable, Equatable, Sendable {
    var start: Int
    var titleLength: Int
    var title: String
    var volume: String?
}

enum TXTAdjustmentError: LocalizedError {
    case invalidSelection, firstChapter, invalidDirectory, staleRevision
    var errorDescription: String? {
        switch self {
        case .invalidSelection: "请选择同一章内连续的非空文字，标题最多 200 字。"
        case .firstChapter: "第一章没有上一章，不能删除。"
        case .invalidDirectory: "分章调整记录无法与当前原文对应，原记录已保留。"
        case .staleRevision: "分章已在其他窗口改变，请关闭后重新打开调整。"
        }
    }
}

/// 只编辑边界，原文始终不变。由调整页面持有工作副本；保存后的边界属于 ReaderSettings 的存储。
struct TXTAdjustmentDocument: Equatable, Sendable {
    let text: String
    var boundaries: [TXTChapterBoundary]

    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: "\n")
    }

    init(text: String, boundaries: [TXTChapterBoundary]) throws {
        self.text = text; self.boundaries = boundaries
        try validate()
    }

    func validate() throws {
        guard !text.isEmpty, boundaries.first?.start == 0 else { throw TXTAdjustmentError.invalidDirectory }
        for (index, boundary) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].start : text.utf16.count
            guard boundary.start >= 0, boundary.start < end, boundary.titleLength >= 0,
                  boundary.titleLength <= end - boundary.start, !boundary.title.isEmpty,
                  boundary.title.count <= 200,
                  Range(NSRange(location: boundary.start, length: end - boundary.start), in: text) != nil,
                  Range(NSRange(location: boundary.start, length: boundary.titleLength), in: text) != nil else {
                throw TXTAdjustmentError.invalidDirectory
            }
        }
    }

    func range(of chapter: Int) -> NSRange {
        let start = boundaries[chapter].start
        let end = chapter + 1 < boundaries.count ? boundaries[chapter + 1].start : text.utf16.count
        return NSRange(location: start, length: end - start)
    }

    func chapter(containing offset: Int) -> Int {
        var low = 0, high = boundaries.count
        while low < high {
            let middle = (low + high) / 2
            if boundaries[middle].start <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    mutating func setTitle(selection: NSRange) throws {
        guard selection.location != NSNotFound, selection.length > 0,
              let selected = Range(selection, in: text) else { throw TXTAdjustmentError.invalidSelection }
        let title = String(text[selected]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw TXTAdjustmentError.invalidSelection }
        let index = chapter(containing: selection.location)
        guard NSMaxRange(selection) <= NSMaxRange(range(of: index)) else { throw TXTAdjustmentError.invalidSelection }
        // 首章的虚拟“全文/前言”也可在章首直接改为真实标题，不产生空章。
        if selection.location == boundaries[index].start {
            boundaries[index].titleLength = selection.length
            boundaries[index].title = title
        } else {
            boundaries.insert(.init(start: selection.location, titleLength: selection.length,
                                    title: title, volume: boundaries[index].volume), at: index + 1)
        }
        try validate()
    }

    mutating func removeChapter(_ index: Int) throws {
        guard boundaries.indices.contains(index) else { throw TXTAdjustmentError.invalidDirectory }
        guard index > 0 else { throw TXTAdjustmentError.firstChapter }
        boundaries.remove(at: index)
    }

    func chapters() -> [TXTChapter] {
        boundaries.indices.map { index in
            let boundary = boundaries[index], region = range(of: index)
            let bodyRange = NSRange(location: region.location + boundary.titleLength, length: region.length - boundary.titleLength)
            let body = (text as NSString).substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
            return TXTChapter(index: index, title: boundary.title, body: body, volumeTitle: boundary.volume)
        }
    }
}

/// 原子写入目录与待承接的阅读状态。迁移保留至下次读取，可在写盘后进程终止时重放；较新状态不覆盖。
struct TXTAdjustmentSnapshot: Codable, Sendable {
    var version = 1
    let contentHash: String
    let revision: String
    let boundaries: [TXTChapterBoundary]
    var position: SyncedReadingPosition?
    var bookmarks: [String: ReaderBookmark]
}

struct TXTAdjustmentSession: Sendable {
    var document: TXTAdjustmentDocument
    var revision: String?
    let baseBook: TXTParsedBook
}

/// ReaderSettings 拥有一个实例。文件与解析在 actor 上运行；不写源 TXT，也不把大书存到偏好里。
actor TXTChapterAdjustmentStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private func file(_ hash: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw TXTAdjustmentError.invalidDirectory }
        return directory.appendingPathComponent(hash + ".json")
    }

    func snapshot(hash: String) throws -> TXTAdjustmentSnapshot? {
        let url = try file(hash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(TXTAdjustmentSnapshot.self, from: Data(contentsOf: url))
        guard value.version == 1, value.contentHash == hash else { throw TXTAdjustmentError.invalidDirectory }
        return value
    }

    func session(url: URL, rules: TXTChapterRuleConfiguration) async throws -> TXTAdjustmentSession {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = FileContentHash.sha256(data)
        guard let decoded = TXTTextDecoder.decode(data: data) else { throw TXTTextDecodingError.unrecognizedEncoding }
        let text = TXTAdjustmentDocument.normalized(decoded)
        let existing = try snapshot(hash: hash)
        let boundaries = existing?.boundaries ?? TXTChapterParser.adjustmentBoundaries(text, rules: rules)
        let document = try TXTAdjustmentDocument(text: text, boundaries: boundaries)
        let base = try await TXTBookCache.shared.book(at: url, rules: rules, source: .open)
        guard base.contentHash == hash else { throw TXTAdjustmentError.invalidDirectory }
        return TXTAdjustmentSession(document: document, revision: existing?.revision, baseBook: base)
    }

    func readingBook(_ base: TXTParsedBook, url: URL) throws -> (book: TXTParsedBook, snapshot: TXTAdjustmentSnapshot?) {
        guard let saved = try snapshot(hash: base.contentHash) else { return (base, nil) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard FileContentHash.sha256(data) == base.contentHash,
              let text = TXTTextDecoder.decode(data: data) else { throw TXTAdjustmentError.invalidDirectory }
        let document = try TXTAdjustmentDocument(text: TXTAdjustmentDocument.normalized(text), boundaries: saved.boundaries)
        let book = TXTParsedBook(contentHash: base.contentHash, byteCount: data.count, text: document.text,
                             chapters: document.chapters(), rulesFingerprint: base.rulesFingerprint + "|adjust:" + saved.revision)
        return (book, saved)
    }

    func save(_ document: TXTAdjustmentDocument, hash: String, expectedRevision: String?,
              position: SyncedReadingPosition?, bookmarks: [String: ReaderBookmark]) throws -> String {
        try document.validate()
        guard try snapshot(hash: hash)?.revision == expectedRevision else { throw TXTAdjustmentError.staleRevision }
        let revision = UUID().uuidString
        let saved = TXTAdjustmentSnapshot(contentHash: hash, revision: revision, boundaries: document.boundaries,
                                          position: position, bookmarks: bookmarks)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: file(hash), options: .atomic)
        return revision
    }
}

/// 与 TextChapterSource 的 36KB UTF-8 切分和纯文本计数相同；仅编辑目录时构建，不在每次翻页扫描全书。
/// 保留段落的原文范围；简繁/文字替换改变长度时，只在该段内近似映射，不把页码当作原文坐标。
struct TXTAdjustmentCoordinates {
    struct Span {
        let rendered: Range<Int>
        let raw: Range<Int>
    }
    struct Unit {
        let chapter: Int
        let start: Int
        let end: Int
        let length: Int
        let spans: [Span]
    }
    let units: [Unit]

    init(text: String, chapters: [TXTChapter], projection: ReadingTextProjection, boundaries: [TXTChapterBoundary]? = nil) throws {
        let source = text as NSString
        var cursor = 0, units = [Unit]()
        for chapter in chapters {
            let body = chapter.body
            let found = source.range(of: body, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { throw TXTAdjustmentError.invalidDirectory }
            cursor = NSMaxRange(found)
            let bytes = body.utf8
            let cuts = TXTTextUnitCuts.cuts(utf8: bytes, maximumUTF8: 36_000)
            for part in 0..<(cuts.count - 1) {
                let lower = bytes.index(bytes.startIndex, offsetBy: cuts[part])
                let upper = bytes.index(bytes.startIndex, offsetBy: cuts[part + 1])
                guard let start = String.Index(lower, within: body), let end = String.Index(upper, within: body) else {
                    throw TXTAdjustmentError.invalidDirectory
                }
                let rawStart = found.location + NSRange(body.startIndex..<start, in: body).length
                let rawEnd = found.location + NSRange(body.startIndex..<end, in: body).length
                var rendered = part == 0 ? projection.apply(chapter.title).utf16.count + projection.apply(chapter.volumeTitle ?? "").utf16.count : 0
                var spans = [Span](), lineStart = rawStart
                let chunk = String(body[start..<end])
                // paragraph trimming 与 TextChapterXHTML.paragraphs(fromLines:) 同口径。
                for line in chunk.components(separatedBy: "\n") {
                    let clean = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
                    if !clean.isEmpty {
                        let local = (line as NSString).range(of: clean)
                        let count = projection.apply(clean).utf16.count
                        spans.append(Span(rendered: rendered..<(rendered + count),
                                          raw: (lineStart + local.location)..<(lineStart + local.location + local.length)))
                        rendered += count
                    }
                    lineStart += line.utf16.count + 1
                }
                let regionStart = part == 0 ? boundaries?[chapter.index].start ?? rawStart : rawStart
                units.append(Unit(chapter: chapter.index, start: regionStart, end: rawEnd, length: rendered, spans: spans))
            }
        }
        guard !units.isEmpty else { throw TXTAdjustmentError.invalidDirectory }
        self.units = units
    }

    func rawOffset(unit: Int, offset: Int) -> Int? {
        guard units.indices.contains(unit) else { return nil }
        let value = units[unit]
        guard let span = value.spans.first(where: { $0.rendered.upperBound > offset }) ?? value.spans.last else { return value.start }
        let fraction = min(1, max(0, Double(offset - span.rendered.lowerBound) / Double(max(1, span.rendered.count))))
        return span.raw.lowerBound + Int(fraction * Double(span.raw.count))
    }

    func location(rawOffset: Int) -> (unit: Int, offset: Int)? {
        guard !units.isEmpty else { return nil }
        let index = units.lastIndex(where: { $0.start <= rawOffset }) ?? 0
        let unit = units[index]
        // 删除标题/新增标题所在的空隙属于新章的起点，不沿用前章末页。
        if rawOffset < (unit.spans.first?.raw.lowerBound ?? unit.start) { return (index, 0) }
        guard let span = unit.spans.first(where: { $0.raw.upperBound > rawOffset }) ?? unit.spans.last else { return (index, 0) }
        let fraction = min(1, max(0, Double(rawOffset - span.raw.lowerBound) / Double(max(1, span.raw.count))))
        return (index, min(unit.length, span.rendered.lowerBound + Int(fraction * Double(span.rendered.count))))
    }
}


/// TXT 分页与目录调整共用同一段落切分，禁止两个实现漂移后复用错误的单元坐标。
public enum TXTTextUnitCuts {
    public static func cuts(utf8: String.UTF8View, maximumUTF8: Int) -> [Int] {
        let scan: (UnsafeBufferPointer<UInt8>) -> [Int] = { bytes in
            var cuts = [0]
            var unitBytes = 0
            var lineStart = 0
            for index in 0...bytes.count {
                guard index == bytes.count || bytes[index] == 0x0A || bytes[index] == 0x0D else { continue }
                let lineBytes = index - lineStart
                if lineBytes > 0 {
                    if unitBytes > 0, unitBytes + lineBytes > maximumUTF8 {
                        cuts.append(lineStart)
                        unitBytes = 0
                    }
                    unitBytes += lineBytes
                }
                lineStart = index + 1
            }
            cuts.append(bytes.count)
            return cuts
        }
        return utf8.withContiguousStorageIfAvailable(scan) ?? Array(utf8).withUnsafeBufferPointer(scan)
    }
}
