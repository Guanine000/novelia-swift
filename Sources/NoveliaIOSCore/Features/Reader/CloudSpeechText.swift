import Foundation

/// 云端按小段合成，避免每句新建 WebSocket。保留原文偏移用于起播，不宣称词级精度。
enum CloudSpeechText {
    struct Chunk: Equatable, Sendable {
        let text: String
        let sourceRange: Range<Int>
        var sourceUTF16Offsets: [Int] = []
        func sourceRange(for range: Range<Int>) -> Range<Int>? {
            guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= sourceUTF16Offsets.count else { return nil }
            return sourceUTF16Offsets[range.lowerBound]..<(sourceUTF16Offsets[range.upperBound - 1] + 1)
        }
    }
    static let maximumEscapedUTF8 = 3_000

    static func chunks(in text: String, startingAt progression: Double = 0, visibleOffset: Int? = nil) -> [Chunk] {
        var output: [Chunk] = []
        var buffer = ""
        var offsets: [Int] = []
        var start = 0
        var end = 0
        let segments = SpeechText.splitAtVisibleOffset(SpeechText.segments(in: text), offset: visibleOffset)
        let startIndex = SpeechText.startIndex(in: segments, chapterUTF16Length: text.utf16.count, progression: progression)
        for (index, segment) in segments.enumerated() {
            // 在起播句强制断段，避免当前页落在大段中部而倒退数页开始朗读。
            if index == startIndex, !buffer.isEmpty {
                output.append(Chunk(text: buffer, sourceRange: start..<end, sourceUTF16Offsets: offsets))
                buffer = ""; offsets = []
            }
            let next = buffer.isEmpty ? segment.text : buffer + "\n" + segment.text
            if !buffer.isEmpty, escapedUTF8Count(next) > maximumEscapedUTF8 {
                output.append(Chunk(text: buffer, sourceRange: start..<end, sourceUTF16Offsets: offsets))
                buffer = ""; offsets = []
            }
            if buffer.isEmpty { start = segment.utf16Offset }
            if !buffer.isEmpty { offsets.append(max(start, segment.utf16Offset - 1)) }
            offsets += segment.sourceUTF16Offsets
            buffer += (buffer.isEmpty ? "" : "\n") + segment.text
            end = segment.sourceRange.upperBound
        }
        if !buffer.isEmpty { output.append(Chunk(text: buffer, sourceRange: start..<end, sourceUTF16Offsets: offsets)) }
        return output
    }

    static func startIndex(in chunks: [Chunk], length: Int, progression: Double) -> Int {
        guard !chunks.isEmpty, length > 0, progression.isFinite else { return 0 }
        let target = min(length - 1, Int(Double(length) * min(1, max(0, progression))))
        return chunks.lastIndex { $0.sourceRange.lowerBound <= target } ?? 0
    }

    static func escapedUTF8Count(_ text: String) -> Int {
        text.utf8.count + text.reduce(0) { count, char in
            count + (char == "&" ? 4 : (char == "<" || char == ">" ? 3 : (char == "\"" || char == "'" ? 5 : 0)))
        }
    }
}

/// 只在当前播放会话内缓存有界音频，不写磁盘，不参与备份或同步；停止时清空。
struct SpeechAudioMemoryCache {
    private var values: [String: CloudSpeechAudio] = [:]
    private var order: [String] = []
    private(set) var byteCount = 0
    let maximumBytes: Int
    init(maximumBytes: Int = 8 * 1_024 * 1_024) { self.maximumBytes = maximumBytes }
    mutating func get(_ key: String) -> Data? { getAudio(key)?.data }
    mutating func getAudio(_ key: String) -> CloudSpeechAudio? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value
    }
    mutating func put(_ value: Data, for key: String) { putAudio(CloudSpeechAudio(data: value, boundaries: []), for: key) }
    mutating func putAudio(_ value: CloudSpeechAudio, for key: String) {
        guard value.data.count <= maximumBytes else { return }
        if let old = values.removeValue(forKey: key) { byteCount -= old.data.count }
        order.removeAll { $0 == key }
        while byteCount + value.data.count > maximumBytes, let first = order.first {
            byteCount -= values.removeValue(forKey: first)?.data.count ?? 0
            order.removeFirst()
        }
        values[key] = value; order.append(key); byteCount += value.data.count
    }
    mutating func removeAll() { values.removeAll(); order.removeAll(); byteCount = 0 }
}
