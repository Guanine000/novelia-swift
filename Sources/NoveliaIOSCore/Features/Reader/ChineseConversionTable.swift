// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 一简对多繁与台湾常用词的修正表。数据由 `scripts/update_chinese_conversion_table.swift`
/// 从 OpenCC 的词组表（Apache-2.0）派生，只保留系统 ICU 会选错字的词组和白名单内的
/// 台湾常用词（软件→軟體、网络→網路），不采用 OpenCC 的古体用字或软件界面专用说法。
/// 键是 ICU 的繁体输出，命中时按最长词修正；资源缺失或解析失败时退回纯 ICU 结果。
/// 首次使用时解析资源并建立前缀树，之后只读复用；由 App 在启动时后台预热。
enum ChineseConversionTable {
    static func apply(_ text: String) -> String { trie?.apply(text) ?? text }
    /// 只触发一次加载，用于 App 启动时提前解析，避免打开第一章时同步读取资源。
    static func warmUp() { _ = trie }

    private static let trie: ReplacementTrie? = load()

    private static func load() -> ReplacementTrie? {
        guard let url = resourceURL, let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rules: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            rules[String(parts[0])] = String(parts[1])
        }
        return rules.isEmpty ? nil : ReplacementTrie(rules)
    }

    private static var resourceURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "ChineseConversionTable", withExtension: "txt")
        #else
        Bundle.main.url(forResource: "ChineseConversionTable", withExtension: "txt")
        #endif
    }
}
