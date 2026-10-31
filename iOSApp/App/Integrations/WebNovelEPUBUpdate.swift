import Foundation
import SwiftSoup

/// 网站/阅读器/WebDAV替换共用的预提交钩子。只读两份文件，不访问网站正文，也不改写EPUB。
@MainActor
enum WebNovelEPUBUpdate {
    static func prepare(book: DownloadedWebNovel, old: URL, new: URL, local: LocalAppServices) async throws {
        let updated = try await EPUBContainer.open(fileURL: new)
        try await updated.validateForReadium()
        guard book.novel.isRemote, let provider = book.novel.providerId, let novel = book.novel.novelId,
              let previous = try? await EPUBContainer.open(fileURL: old) else { return }
        let hashes = try await Task.detached(priority: .utility) {
            (try FileContentHash.sha256(old), try FileContentHash.sha256(new))
        }.value
        try Task.checkCancellation()
        let key = WebNovelEPUBContext.key(provider: provider, novel: novel)
        let context = local.readerSettings.webEPUBMaps.context(bookKey: key, hash: hashes.0)
        try WebNovelEPUBMigration.migrate(context: context, paths: previous.spine.map(\.href), settings: local.readerSettings)
        guard hashes.0 != hashes.1,
              let source = local.readerSettings.webEPUBMaps.maps[key + ":" + hashes.0], !source.chapterIDs.isEmpty else { return }
        let oldResources = try await resources(previous)
        let newResources = try await resources(updated)
        try Task.checkCancellation()
        // 解析期间其他设备可能补全/更正映射；提交前复读共用Store，不用过期快照覆盖。
        let latestSource = local.readerSettings.webEPUBMaps.maps[source.key] ?? source
        let targetKey = key + ":" + hashes.1
        let target = local.readerSettings.webEPUBMaps.maps[targetKey] ?? WebNovelEPUBMap(bookKey: key, fileHash: hashes.1, bindings: [:])
        let inherited = WebNovelEPUBFileMatcher.inherit(old: oldResources, new: newResources, source: latestSource, target: target)
        // 按文件hash缓存有效对应；若随后取消/事务冲突，仅留下该文件的可复用映射，不替换原书或提升阅读时间。
        if inherited != target { try local.readerSettings.webEPUBMaps.merge([inherited.key: inherited]) }
    }
    private static func resources(_ container: EPUBContainer) async throws -> [WebNovelEPUBFileMatcher.Resource] {
        let indices = container.spine.indices.filter {
            container.spine[$0].href.range(of: #"(?:^|/)episode[0-9]+\.xhtml$"#, options: .regularExpression) != nil
        }
        var result: [WebNovelEPUBFileMatcher.Resource] = []
        for index in indices.isEmpty ? Array(container.spine.indices) : indices {
            try Task.checkCancellation()
            let html = try await container.chapterHTML(at: index), path = container.spine[index].href
            let resource = try await Task.detached(priority: .utility) {
                let doc = try SwiftSoup.parse(html)
                return WebNovelEPUBFileMatcher.Resource(path: path,
                    heading: try doc.select("h1,h2").array().map { try $0.text() }.joined(separator: "\u{1f}"),
                    body: try doc.select("p").array().map { try $0.text() }.joined(separator: "\n"))
            }.value
            result.append(resource)
        }
        return result
    }
}
