import CoreText
import Foundation
import UIKit

// 阅读样式与导入字体。Readium 与原生分页共用，且不依赖 YueduCoreText。
// iOS 15 目标不编译原生分页源文件，因此这两类放在独立文件里，两个 App 目标都编译。

/// 阅读器自己的排版偏好；字体名称来自设备当前可用的 UIFont 字体族。
struct EPUBReaderStyle: Codable, Equatable {
    var doublePage: Bool? = false
    var fontSize: CGFloat = 21
    var fontFamily: String? = nil
    var lineSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
    /// nil 保留书籍原样；0、1、2 等值覆盖段落首行缩进（em）。
    var firstLineIndentEm: CGFloat? = nil
    var topMargin: CGFloat = 64
    var bottomMargin: CGFloat = 72
    var leftMargin: CGFloat = 20
    var rightMargin: CGFloat = 20

    var contentInsets: UIEdgeInsets {
        UIEdgeInsets(top: topMargin, left: leftMargin, bottom: bottomMargin, right: rightMargin)
    }

    var readerCSS: String? {
        var rules: [String] = []
        if let fontFamily {
            let escaped = fontFamily.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            rules.append("body, p { font-family: '\(escaped)' !important; }")
        }
        if let firstLineIndentEm {
            rules.append("p { text-indent: \(firstLineIndentEm)em !important; }")
        }
        return rules.isEmpty ? nil : rules.joined(separator: "\n")
    }
}

@MainActor
enum EPUBLocalFonts {
    struct ImportedFont: Identifiable {
        let url: URL
        let family: String
        var id: URL { url }
        var format: String { url.pathExtension.uppercased() }
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EPUBReaderFonts", isDirectory: true)
    }

    static func registerSavedFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    static func importFont(from sourceURL: URL) throws -> String {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        guard ["ttf", "otf", "ttc"].contains(sourceURL.pathExtension.lowercased()) else {
            throw FontImportError.unsupportedFormat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension.lowercased())
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let registered = CTFontManagerRegisterFontsForURL(destination as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(destination as CFURL) as? [CTFontDescriptor],
              let family = descriptors.compactMap({ CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }).first else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        guard registered || UIFont.familyNames.contains(family) else {
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.registrationFailed
        }
        let hash = try FileContentHash.sha256(destination)
        recordSync(SyncedImportedFont(hash: hash, format: destination.pathExtension, deleted: false, updatedAt: Date()))
        return family
    }

    static func importedFonts() -> [ImportedFont] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file in
            guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
                  let family = descriptors.compactMap({
                      CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
                  }).first else { return nil }
            return ImportedFont(url: file, family: family)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    static func deleteFont(_ font: ImportedFont) throws {
        guard font.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw FontImportError.invalidLocation
        }
        let hash = try FileContentHash.sha256(font.url)
        CTFontManagerUnregisterFontsForURL(font.url as CFURL, .process, nil)
        try FileManager.default.removeItem(at: font.url)
        recordSync(SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: true, updatedAt: Date()))
    }

    static func syncSnapshot() throws -> [String: SyncedImportedFont] {
        var records = syncRecords()
        for font in importedFonts() {
            let hash = try FileContentHash.sha256(font.url)
            if records[hash] == nil { records[hash] = SyncedImportedFont(hash: hash, format: font.url.pathExtension, deleted: false, updatedAt: .distantPast) }
        }
        return records
    }
    static func syncFiles() throws -> [String: URL] {
        var files: [String: URL] = [:]
        for font in importedFonts() { files[try FileContentHash.sha256(font.url)] = font.url }
        return files
    }
    private static func syncRecords() -> [String: SyncedImportedFont] {
        UserDefaults.standard.data(forKey: SettingsKey.importedFontSync).flatMap { try? JSONDecoder().decode([String: SyncedImportedFont].self, from: $0) } ?? [:]
    }
    private static func recordSync(_ record: SyncedImportedFont) {
        var records = syncRecords(); records[record.hash] = record
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: SettingsKey.importedFontSync) }
    }
    static func applySync(_ records: [String: SyncedImportedFont], files: [String: URL]) throws {
        for (hash, record) in records {
            if let local = syncRecords()[hash], local.updatedAt > record.updatedAt { continue }
            let matches = try importedFonts().filter { try FileContentHash.sha256($0.url) == hash }
            if record.deleted {
                for font in matches { try deleteFont(font) }
            } else if matches.isEmpty {
                guard ["ttf", "otf", "ttc"].contains(record.format), let file = files[hash] else { throw CocoaError(.fileReadCorruptFile) }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(record.format)
                try FileManager.default.copyItem(at: file, to: temporary)
                defer { try? FileManager.default.removeItem(at: temporary) }
                _ = try importFont(from: temporary)
            }
            recordSync(record)
        }
        NotificationCenter.default.post(name: Notification.Name("NoveliaImportedFontsChanged"), object: nil)
    }

    private enum FontImportError: LocalizedError {
        case unsupportedFormat, registrationFailed, invalidLocation
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "请选择 TTF、OTF 或 TTC 字体文件。"
            case .registrationFailed: "无法注册该字体文件，请确认文件完整且格式受 iOS 支持。"
            case .invalidLocation: "只能删除本应用导入的字体。"
            }
        }
    }
}

/// 注释浮层的正文。原生分页与 Readium 共用，不依赖 YueduCoreText。
struct EPUBNote: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
