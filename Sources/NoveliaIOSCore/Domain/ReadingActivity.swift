import Foundation

/// 统计中的阅读类型；rawValue 会持久化并同步，修改名称时需处理旧记录兼容。
enum ReadingKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case epub, txt, online
    var id: String { rawValue }
    var title: String {
        switch self {
        case .epub: "EPUB"
        case .txt: "TXT"
        case .online: "在线阅读"
        }
    }
}

/// 计时事件携带的书籍身份与显示信息；不包含阅读器实例，稳定 ID 用于关联历史统计。
struct ReadingBook: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ReadingKind
}

