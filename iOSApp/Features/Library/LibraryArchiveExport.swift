import Foundation
import ReadiumZIPFoundation
import SwiftUI
import UIKit

/// 待分享的压缩包：临时 zip 文件与展示用的标题。
struct LibraryArchiveShare: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

enum LibraryArchiveExportError: LocalizedError {
    /// 选中的书都没有本机文件（全部只在云端）。
    case noReadableBooks
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReadableBooks:
            "选中的书都只在云端，没有可压缩的本机文件。请先下载后再分享。"
        case .createFailed(let reason):
            "压缩失败：\(reason)"
        }
    }
}

/// 把多本书的原文件打成一个 zip 供系统分享；只读取书库中的文件，不修改原书。
@MainActor
enum LibraryArchiveExporter {
    static func makeArchive(books: [LibraryBook], title: String) async throws -> LibraryArchiveShare {
        let localBooks = books.filter { !$0.isCloudOnly }
        guard !localBooks.isEmpty else { throw LibraryArchiveExportError.noReadableBooks }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoveliaShare", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let staging = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archiveURL = base.appendingPathComponent("\(sanitized(title)).zip")
        try? FileManager.default.removeItem(at: archiveURL)

        do {
            let archive = try await Archive(url: archiveURL, accessMode: .create)
            var usedNames = Set<String>()
            for (index, book) in localBooks.enumerated() {
                let number = String(format: "%02d", index + 1)
                let fileExtension = book.fileURL.pathExtension.isEmpty ? "txt" : book.fileURL.pathExtension
                let entry = unique(
                    base: "\(number) \(sanitized(book.title))",
                    suffix: fileExtension,
                    usedNames: &usedNames
                )
                try await archive.addEntry(with: entry, fileURL: book.fileURL, compressionMethod: .deflate)
            }
            return LibraryArchiveShare(url: archiveURL, title: title)
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw LibraryArchiveExportError.createFailed(error.localizedDescription)
        }
    }

    /// 去掉路径分隔符与文件名保留字符，避免压缩条目或 zip 文件名非法。
    private static func sanitized(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : String(trimmed.prefix(80))
    }

    /// 同名书加序号，保证 zip 中条目唯一。
    private static func unique(base: String, suffix: String, usedNames: inout Set<String>) -> String {
        var candidate = suffix.isEmpty ? base : "\(base).\(suffix)"
        var counter = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = suffix.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(suffix)"
            counter += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }
}

/// 直接弹出系统分享面板；完成后由 `onDismiss` 复位状态。
struct LibraryArchiveShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
