#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-only
//
// 生成繁体显示的修正表，合并成一份资源，运行期在 ICU 转换之后做一次最长匹配替换。
//
// 两部分：
// 1. 一简对多繁选字（STPhrases）：ICU 对常见词大多正确，只在词组层面偶尔选错字
//    （一干二净、诗云、干嘛）。只保留差异落在下方 oneToMany 白名单上的词条，并且
//    只取三字以上词组；两字词只接受 forceWords 里逐个核对过的常用词，避免「乾一」
//    这类词典碎片在正文里误伤更长的词。
// 2. 台湾用词（TWPhrases）：只取 taiwanWords 白名单里的日常词，避免把只在软件语境
//    成立的映射（循环→迴圈、对象→物件、保存→儲存、打开→開啟）套到小说正文上。
//    生成时把两层合成一次替换，运行期不链式转换。
//
// 两种来源都按 canonical 归一异体字，键以 ICU 输出为准；ICU 版本变化只会让个别
// 条目不再命中，不会改错文本。
//
// 用法：在仓库根目录执行 `swift scripts/update_chinese_conversion_table.swift`
// 数据来源：https://github.com/BYVoid/OpenCC data/dictionary（Apache-2.0）

import Foundation

let openCCTag = "ver.1.4.2"
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let destination = root.appendingPathComponent("Sources/NoveliaIOSCore/Resources/ChineseConversionTable.txt")
let transform = StringTransform("Simplified-Traditional")
let reverseTransform = StringTransform("Traditional-Simplified")

// 一简对多繁的简化字：只有这些字上的差异视为选字修正。
let oneToMany: Set<Character> = Set("干发只台里面松卷制表谷后系历复范钟种云余划斗舍折托赞准冲采蒙了几于周咸凶岩布沈伙板胡郁")
// 两字词组依赖上下文，只收逐个核对过的常用说法。
let forceWords: Set<String> = ["干嘛", "干吗", "干啥", "干仗", "干事", "干练", "诗云", "云云", "才干", "干才", "干将"]
// 台湾日常用词白名单：只收跨语境成立的词，不取软件界面专用说法。
let taiwanWords: [String] = [
    // 只列 OpenCC TWPhrases 里确实存在、且脱离软件界面也成立的说法。
    "信息", "短信", "软件", "硬件", "网络", "互联网", "局域网", "内存", "硬盘", "鼠标",
    "打印机", "服务器", "数据库", "主板", "宽带", "在线", "博客", "视频", "像素",
    "分辨率", "默认", "光标", "光盘", "扫描仪", "人工智能", "出租车",
]
// 同一繁体词的异体写法：统一到通用字形。
let canonical: [Character: Character] = [
    "臺": "台", "裏": "裡", "麪": "麵", "喫": "吃", "纔": "才", "爲": "為",
    "衆": "眾", "羣": "群", "綫": "線", "汙": "污", "牀": "床", "峯": "峰",
    "盃": "杯",
]

func fetch(_ dictionary: String) throws -> String {
    let url = URL(string: "https://raw.githubusercontent.com/BYVoid/OpenCC/\(openCCTag)/data/dictionary/\(dictionary)")!
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}
func entries(_ text: String) -> [(String, String)] {
    text.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 2, let first = String(parts[1]).split(separator: " ").first else { return nil }
        return (String(parts[0]), String(first))
    }
}
func normalize(_ text: String) -> String { String(text.map { canonical[$0] ?? $0 }) }
func toTraditional(_ text: String) -> String { normalize(text.applyingTransform(transform, reverse: false) ?? text) }

/// 生成期使用的替换器：按首字符分桶后最长匹配。
struct Replacer {
    let buckets: [Character: [String]]
    let rules: [String: String]
    init(_ rules: [String: String]) {
        var buckets: [Character: [String]] = [:]
        for key in rules.keys { buckets[key.first!, default: []].append(key) }
        for key in buckets.keys { buckets[key]!.sort { $0.count == $1.count ? $0 < $1 : $0.count > $1.count } }
        self.buckets = buckets; self.rules = rules
    }
    func apply(_ text: String) -> String {
        let characters = Array(text)
        var result = "", index = 0
        while index < characters.count {
            var matched: String?
            for key in buckets[characters[index]] ?? [] where characters[index...].starts(with: Array(key)) {
                matched = key; break
            }
            if let matched { result += rules[matched] ?? ""; index += matched.count }
            else { result.append(characters[index]); index += 1 }
        }
        return result
    }
}

guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
    FileHandle.standardError.write(Data("请在仓库根目录运行。\n".utf8))
    exit(1)
}

// 1. 选字修正：键是 ICU 输出，值是 OpenCC 的繁体写法（尚未做台湾用词替换）。
var corrections: [String: String] = [:]
var variantOnly = 0, shortDropped = 0, wrongCharacter = 0, lengthMismatch = 0, duplicates = 0
for (simplifiedText, traditionalText) in entries(try fetch("STPhrases.txt")) {
    let simplified = Array(simplifiedText)
    let traditional = Array(normalize(traditionalText))
    let converted = Array(toTraditional(simplifiedText))
    guard converted != traditional else { continue }
    guard converted.count == traditional.count, converted.count == simplified.count else { lengthMismatch += 1; continue }
    if simplified == traditional, simplified.count <= 2, !forceWords.contains(simplifiedText) { shortDropped += 1; continue }
    let value = Array(traditional)
    guard converted != value else { variantOnly += 1; continue }
    let differences = converted.indices.filter { converted[$0] != value[$0] }
    guard differences.allSatisfy({ oneToMany.contains(simplified[$0]) }) else { wrongCharacter += 1; continue }
    let key = String(converted), text = String(value)
    if let existing = corrections[key], existing != text { duplicates += 1; continue }
    corrections[key] = text
}
let correctionReplacer = Replacer(corrections)

// 2. 台湾用词：只取白名单词的映射，避免软件专用说法流入正文。
let twLookup = Dictionary(entries(try fetch("TWPhrases.txt")).map { (normalize($0.0), normalize($0.1)) },
                          uniquingKeysWith: { first, _ in first })
var taiwan: [String: String] = [:]
for word in taiwanWords {
    let base = toTraditional(word), corrected = correctionReplacer.apply(base)
    guard let mapped = twLookup[corrected] ?? twLookup[base], mapped != corrected else { continue }
    taiwan[corrected] = mapped
}
let taiwanReplacer = Replacer(taiwan)

// 3. 合并：先选字、再台湾用词，合成一次替换。
var rows: [String: String] = [:]
for (key, value) in corrections { rows[key] = taiwanReplacer.apply(value) }
for word in taiwanWords {
    let base = toTraditional(word), localized = taiwanReplacer.apply(correctionReplacer.apply(base))
    guard localized != base else { continue }
    if let existing = rows[base], existing != localized { duplicates += 1; continue }
    rows[base] = localized
}
rows = rows.filter { $0.key != $0.value }

var output = """
# 由 scripts/update_chinese_conversion_table.swift 生成，请勿手工编辑。
# 来源：OpenCC \(openCCTag) data/dictionary 的 STPhrases.txt 与 TWPhrases.txt（Apache-2.0）。
# 每行是「ICU 简体转繁体的输出 <TAB> 修正结果」：繁体显示已合成一简对多繁选字与台湾常用词。
# 未命中的文本保持 ICU 输出。

"""
for key in rows.keys.sorted() { output += key + "\t" + (rows[key] ?? "") + "\n" }
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
try output.write(to: destination, atomically: true, encoding: .utf8)
print("写出 \(rows.count) 条，\(output.utf8.count / 1024) KB；选字修正 \(corrections.count)，台湾用词 \(taiwan.count)")
print("选字跳过：异体归一后相同 \(variantOnly)、两字未核对 \(shortDropped)、非白名单字 \(wrongCharacter)、长度不一致 \(lengthMismatch)、冲突 \(duplicates)")
let missed = taiwanWords.filter { word in
    let base = toTraditional(word), localized = taiwanReplacer.apply(correctionReplacer.apply(base))
    return localized == base
}
if !missed.isEmpty { print("白名单未命中：", missed.joined(separator: "、")) }
