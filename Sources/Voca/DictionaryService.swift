// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import GRDB

/// 一条词典词条（数据源 ECDICT，bundle 内只读 SQLite）
struct DictionaryEntry: Equatable, Codable, FetchableRecord {
    let word: String
    /// 英式 DJ 音标（ECDICT 原始记法，显示前经 `prettifiedPhonetic` 转写）
    let phonetic: String
    /// 中文释义
    let translation: String
    /// 英文释义（可能为空）
    let definition: String
    /// 词形变换描述（"0:原形/1:类型/d:过去式/..."）
    let exchange: String
    /// 考试标签（zk/gk/cet4/cet6/ky/toefl/ielts/gre，空格分隔）
    let tag: String
    /// 柯林斯星级 0-5
    let collins: Int
    /// 是否牛津 3000 核心词
    let oxford: Int
    /// BNC 语料库词频排名（0 = 无排名）
    let bnc: Int
    /// 当代语料库词频排名（0 = 无排名）
    let frq: Int

    /// 该词条是否是原形（无 "0:原形" 指向）
    var isLemmaForm: Bool {
        exchangeCode(prefixed: "0:") == nil
    }

    /// 从 exchange 里取指定前缀码的值（如 "0:" → 原形词）
    func exchangeCode(prefixed prefix: String) -> String? {
        for part in exchange.split(separator: "/") {
            if part.hasPrefix(prefix) {
                let value = part.dropFirst(prefix.count)
                return value.isEmpty ? nil : String(value)
            }
        }
        return nil
    }
}

/// 查询结果：命中的词条 +（若是词形变体时）其原形词条
struct DictionaryLookupResult: Equatable {
    let entry: DictionaryEntry
    let lemma: DictionaryEntry?
}

/// 内嵌词典查询：bundle 内 dictionary.sqlite 只读访问。
///
/// 查询链：原文 → 清洗（引号/所有格/首尾标点）→ 大小写不敏感精确匹配；
/// 命中词形变体（went）时顺带取回原形（go）词条。
final class DictionaryService: @unchecked Sendable {
    /// 词典元信息（来源/条目数等，设置页展示）
    struct Meta {
        let source: String
        let sourceURL: String
        let license: String
        let entries: Int
        let generated: String
    }
    /// 共享实例：bundle 内词典缺失时退化为永远查不到
    static let shared = DictionaryService(bundleResource: "dictionary", extension: "sqlite")

    private let dbQueue: DatabaseQueue?

    init(url: URL?) {
        guard let url else {
            dbQueue = nil
            return
        }
        var config = Configuration()
        config.readonly = true
        dbQueue = try? DatabaseQueue(path: url.path, configuration: config)
    }

    convenience init(bundleResource name: String, extension ext: String) {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            self.init(url: nil)
            return
        }
        self.init(url: url)
    }

    /// 查词；未命中或词典不可用时返回 nil
    func lookup(_ raw: String) -> DictionaryLookupResult? {
        guard let dbQueue else { return nil }
        let word = Self.normalizedWord(raw)
        guard !word.isEmpty else { return nil }
        guard let entry = fetch(word, in: dbQueue) else { return nil }
        var lemma: DictionaryEntry?
        if let lemmaWord = entry.exchangeCode(prefixed: "0:"),
            lemmaWord.caseInsensitiveCompare(entry.word) != .orderedSame {
            lemma = fetch(lemmaWord, in: dbQueue)
        }
        return DictionaryLookupResult(entry: entry, lemma: lemma)
    }

    private func fetch(_ word: String, in dbQueue: DatabaseQueue) -> DictionaryEntry? {
        var result: DictionaryEntry?
        // 主键大小写不敏感单行查询；只读库无写竞争，异常吞掉返回 nil
        _ = try? dbQueue.read { db in
            result = try DictionaryEntry.fetchOne(
                db,
                sql: """
                    SELECT word, phonetic, translation, definition, exchange,
                           tag, collins, oxford, bnc, frq
                    FROM dictionary WHERE word = ? COLLATE NOCASE
                    """,
                arguments: [word]
            )
        }
        return result
    }

    /// 词典元信息；词典不可用时返回 nil
    var meta: Meta? {
        guard let dbQueue else { return nil }
        var meta: Meta?
        _ = try? dbQueue.read { db in
            func value(_ key: String) -> String {
                (try? String.fetchOne(
                    db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]
                )) ?? ""
            }
            meta = Meta(
                source: value("source"),
                sourceURL: value("source_url"),
                license: value("source_license"),
                entries: Int(value("entries")) ?? 0,
                generated: value("generated")
            )
        }
        return meta
    }

    // MARK: - 文本判定与清洗

    /// 是否含 CJK 表意文字（汉字）
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { Self.isCJKScalar($0) }
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF,
             0x2A700...0x2EBEF, 0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    /// 是否值得弹查词/翻译浮窗：非空、不过长、含拉丁字母或汉字。
    /// 词典未命中但满足此条件的文本（短语/句子/中文）走系统翻译。
    static func isTranslatable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return false }
        var hasLatin = false
        var hasCJK = false
        for scalar in trimmed.unicodeScalars {
            if isCJKScalar(scalar) { hasCJK = true }
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
                hasLatin = true
            }
        }
        return hasLatin || hasCJK
    }

    /// 查询前的清洗：弯引号转直引号、去首尾标点、去所有格 's
    static func normalizedWord(_ text: String) -> String {
        var word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteMap = [
            "’": "'", "‘": "'", "“": "\"", "”": "\"", "「": "", "」": "",
        ]
        for (curly, straight) in quoteMap {
            word = word.replacingOccurrences(of: curly, with: straight)
        }
        let trimmable = Set("\"'.,;:!?()[]()—-")
        while let first = word.first, trimmable.contains(first) {
            word.removeFirst()
        }
        while let last = word.last, trimmable.contains(last) {
            word.removeLast()
        }
        if word.count > 2, word.lowercased().hasSuffix("'s") {
            word.removeLast(2)
        }
        return word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 展示用格式化

    /// ECDICT 释义以字面 "\n"（反斜杠+n）分隔义项，展示时转为真换行
    static func displayText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// ECDICT 音标转写为常规 IPA 显示：ә→ə、:→ː，并补 / / 包裹
    static func prettifiedPhonetic(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var phonetic = raw
            .replacingOccurrences(of: "ә", with: "ə")
            .replacingOccurrences(of: ":", with: "ː")
        if !phonetic.hasPrefix("/") { phonetic = "/" + phonetic }
        if !phonetic.hasSuffix("/") { phonetic += "/" }
        return phonetic
    }

    /// 考试标签码转中文（未知码原样保留）
    static func localizedTags(_ tag: String) -> [String] {
        let known = [
            "zk": "中考", "gk": "高考", "cet4": "四级", "cet6": "六级",
            "ky": "考研", "toefl": "托福", "ielts": "雅思", "gre": "GRE",
        ]
        return tag.split(separator: " ").map { known[String($0)] ?? String($0) }
    }
}
