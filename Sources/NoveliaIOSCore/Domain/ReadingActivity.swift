import Foundation

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

struct ReadingBook: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ReadingKind
}

