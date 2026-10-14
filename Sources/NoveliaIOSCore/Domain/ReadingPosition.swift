import Foundation

struct SyncedReadingPosition: Codable, Equatable {
    /// 网络小说：章节序号。EPUB：spine 序号（保存偏移量之前的版本没有该字段）。
    /// TXT（`txt:<hash>`）：按阅读器章节规则得到的章节序号。
    var chapterIndex: Int?
    /// EPUB：全书进度，为旧版应用保留。
    var fraction: Double?
    var updatedAt: Date
    /// EPUB：页面首段文字在章节源文本中的 UTF-16 偏移量，
    /// 字体或布局变化后重新分页时仍可用于恢复位置。
    var chapterOffset: Int? = nil
    /// 仅 TXT：分页单元及单元总数；此时 `chapterOffset` 表示该单元内的偏移量。
    /// 旧版应用解码时忽略这两个字段。
    var unit: Int? = nil
    var unitCount: Int? = nil
    /// EPUB：当前位置之前的章节文本比例（0...1）。两个 EPUB 引擎都会写入，
    /// 以便互相恢复章内位置；旧版应用忽略此字段，
    /// 回退到 `fraction`。
    var chapterProgression: Double? = nil

    /// 远端位置的时间不早于本地位置时，替换本地位置。
    static func merged(_ local: [String: Self], _ remote: [String: Self]) -> [String: Self] {
        var result = local
        for (key, value) in remote where value.updatedAt >= (result[key]?.updatedAt ?? .distantPast) {
            result[key] = value
        }
        return result
    }
}

