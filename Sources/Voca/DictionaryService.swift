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
import os

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

/// 查询结果：命中的词条 +（若是词形变体时）其原形词条 + 学习增强内容
struct DictionaryLookupResult: Equatable {
    let entry: DictionaryEntry
    let lemma: DictionaryEntry?
    /// 术语库补充（scripts/terms.csv）：与原释义并存展示，不覆盖
    var term: DictionaryEntry?
    var enrichment: DictionaryEnrichment?
}

/// 词典卡的学习增强内容（词根/词形家族/相关短语/同义词）
struct DictionaryEnrichment: Equatable {
    struct RootPart: Equatable {
        let key: String
        let meaning: String
        let origin: String
        let examples: [String]
        /// true = 直接标注（wordroot 例词反查），false = 边界智能拆解
        let direct: Bool

        /// 展示名：多别名 key 取首个（"spect, spec"→spect），去尾部编号（"in-1"→in-）
        var displayName: String {
            var name = key.split(separator: ",").first.map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? key
            while let last = name.last, last.isNumber {
                name.removeLast()
            }
            return name
        }
    }

    /// 词根/词缀拆解（按词内位置排序）
    var roots: [RootPart] = []
    /// 词形家族（原形的全部变化形式）
    var family: [(label: String, form: String)] = []
    /// 包含该词的常用短语
    var phrases: [String] = []
    /// 英英同义词（Moby Thesaurus，公有领域）
    var synonyms: [String] = []

    static func == (lhs: DictionaryEnrichment, rhs: DictionaryEnrichment) -> Bool {
        lhs.roots == rhs.roots && lhs.family.map(\.form) == rhs.family.map(\.form)
            && lhs.phrases == rhs.phrases && lhs.synonyms == rhs.synonyms
    }
}

/// 内嵌词典查询：bundle 内 dictionary.sqlite 只读访问。
///
/// 查询链：原文 → 清洗（引号/所有格/首尾标点）→ 大小写不敏感精确匹配；
/// 命中词形变体（went）时顺带取回原形（go）词条。
final class DictionaryService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "local.voca.Voca", category: "dictionary")
    /// 词典元信息（来源/条目数等，设置页展示）
    struct Meta {
        let source: String
        let sourceURL: String
        let license: String
        let entries: Int
        let generated: String
    }
    /// 共享实例：优先用用户目录的完整版词典（本地自构建，不入库），
    /// 否则用 bundle 内精简版；两者都缺失时退化为永远查不到
    static let shared = DictionaryService(userOverride: "dictionary-full.sqlite")
        ?? DictionaryService(bundleResource: "dictionary", extension: "sqlite")

    /// 用户目录覆盖：~/Library/Application Support/Voca/<name> 存在时启用，否则 nil；
    /// 无论用哪套词典，术语覆盖库始终从 bundle 加载
    private convenience init?(userOverride name: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Voca", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        Self.logger.info("使用用户目录词典：\(url.path, privacy: .public)")
        let termsURL = AppResources.module.url(forResource: "terms", withExtension: "sqlite")
        self.init(url: url, termsURL: termsURL)
    }

    private let dbQueue: DatabaseQueue?
    /// 术语覆盖库（scripts/make_terms.py 生成）：查词时最高优先级修正释义
    private let termsQueue: DatabaseQueue?

    init(url: URL?, termsURL: URL? = nil) {
        guard let url else {
            dbQueue = nil
            termsQueue = nil
            return
        }
        var config = Configuration()
        config.readonly = true
        dbQueue = try? DatabaseQueue(path: url.path, configuration: config)
        termsQueue = termsURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path)
                ? try? DatabaseQueue(path: $0.path, configuration: config)
                : nil
        }
    }

    convenience init(bundleResource name: String, extension ext: String) {
        guard let url = AppResources.module.url(forResource: name, withExtension: ext) else {
            self.init(url: nil)
            return
        }
        let termsURL = AppResources.module.url(forResource: "terms", withExtension: "sqlite")
        self.init(url: url, termsURL: termsURL)
    }

    /// 查词；未命中或词典不可用时返回 nil
    func lookup(_ raw: String) -> DictionaryLookupResult? {
        guard let dbQueue else { return nil }
        let word = Self.normalizedWord(raw)
        guard !word.isEmpty else { return nil }
        guard let entry = fetch(word, in: dbQueue) else {
            // 词典未命中但术语库命中：直接作为词条返回（如 sim2real/VLA）
            if let term = fetchTerm(word) {
                return DictionaryLookupResult(
                    entry: term, lemma: nil, term: nil, enrichment: nil
                )
            }
            return nil
        }
        var lemma: DictionaryEntry?
        if let lemmaWord = entry.exchangeCode(prefixed: "0:"),
            lemmaWord.caseInsensitiveCompare(entry.word) != .orderedSame {
            lemma = fetch(lemmaWord, in: dbQueue)
        }
        // 术语补充：优先查原词，其次查词形原形；与原释义并存
        let term = fetchTerm(word) ?? lemma.flatMap { fetchTerm($0.word) }
        return DictionaryLookupResult(
            entry: entry,
            lemma: lemma,
            term: term,
            enrichment: enrich(entry: entry, lemma: lemma, in: dbQueue)
        )
    }

    /// 术语库查询（scripts/make_terms.py 生成的 terms 表）
    private func fetchTerm(_ word: String) -> DictionaryEntry? {
        guard let termsQueue else { return nil }
        let row = try? termsQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT word, translation, definition, tag FROM terms WHERE word = ? COLLATE NOCASE",
                arguments: [word]
            )
        }
        guard let row else { return nil }
        return DictionaryEntry(
            word: row["word"], phonetic: "", translation: row["translation"],
            definition: row["definition"], exchange: "", tag: row["tag"],
            collins: 0, oxford: 0, bnc: 0, frq: 0
        )
    }

    // MARK: - 学习增强内容

    /// 词根库内存缓存（611 条，首次使用时加载）
    /// key 可含多别名（"spect, spec"），前缀/后缀条目去掉尾部编号（"in-1"→"in"）
    struct RootAlias: Equatable {
        enum Kind { case prefix, root, suffix }
        let key: String
        let meaning: String
        let origin: String
        let examples: [String]
        let kind: Kind
        let alias: String
    }

    private var rootCache: [RootAlias]?

    private func enrich(
        entry: DictionaryEntry, lemma: DictionaryEntry?, in dbQueue: DatabaseQueue
    ) -> DictionaryEnrichment? {
        var result = DictionaryEnrichment()
        // 主展示词：变体取原形，否则词条本身
        let head = lemma ?? entry
        let headWord = head.word.lowercased()

        result.roots = roots(for: headWord, in: dbQueue)
        result.family = Self.familyForms(of: head)
        // 短语/同义词只对单词查（短语查短语无意义且慢）
        if !headWord.contains(" ") {
            result.phrases = phrases(containing: headWord, in: dbQueue)
            result.synonyms = synonyms(for: headWord, in: dbQueue) ?? []
        }
        if result.roots.isEmpty && result.family.isEmpty
            && result.phrases.isEmpty && result.synonyms.isEmpty {
            return nil
        }
        return result
    }

    /// 词根：直接标注优先，无标注且开关开启时智能拆解
    func roots(for word: String, in dbQueue: DatabaseQueue) -> [DictionaryEnrichment.RootPart] {
        if let direct = directRoots(for: word, in: dbQueue), !direct.isEmpty {
            return direct
        }
        guard Self.rootDecompositionEnabled else { return [] }
        return Self.decompose(word: word, aliases: rootTable(in: dbQueue))
    }

    static var rootDecompositionEnabled: Bool {
        UserDefaults.standard.object(forKey: "rootDecompositionEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "rootDecompositionEnabled")
    }

    private func directRoots(
        for word: String, in dbQueue: DatabaseQueue
    ) -> [DictionaryEnrichment.RootPart]? {
        var keys: String?
        _ = try? dbQueue.read { db in
            keys = try String.fetchOne(
                db, sql: "SELECT root_keys FROM word_roots WHERE word = ? COLLATE NOCASE",
                arguments: [word]
            )
        }
        guard let keys, !keys.isEmpty else { return nil }
        let table = rootTable(in: dbQueue)
        return keys.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { key in table.first { $0.key == key } }
            .map { DictionaryEnrichment.RootPart(
                key: $0.key, meaning: $0.meaning, origin: $0.origin,
                examples: $0.examples, direct: true
            ) }
    }

    private func rootTable(in dbQueue: DatabaseQueue) -> [RootAlias] {
        if let rootCache { return rootCache }
        var all: [RootAlias] = []
        _ = try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT key, meaning, class, origin, examples FROM roots"
            )
            for row in rows {
                let key: String = row["key"]
                let wordClass: String = row["class"]
                let examplesRaw: String = row["examples"]
                let kind: RootAlias.Kind
                if wordClass.contains("prefix") {
                    kind = .prefix
                } else if wordClass.contains("suffix") {
                    kind = .suffix
                } else {
                    kind = .root
                }
                for alias in key.split(separator: ",") {
                    let trimmed = alias.trimmingCharacters(
                        in: CharacterSet(charactersIn: " 0123456789-"))
                    guard trimmed.count >= 2 else { continue }
                    all.append(RootAlias(
                        key: key, meaning: row["meaning"], origin: row["origin"],
                        examples: examplesRaw.isEmpty
                            ? [] : examplesRaw.components(separatedBy: ", "),
                        kind: kind, alias: trimmed
                    ))
                }
            }
        }
        rootCache = all
        return all
    }

    /// 边界智能拆解：前缀（词首最长匹配）+ 词根（贪心最长匹配，≥3 字母）+ 后缀（词尾最长匹配）；
    /// 找不到词根则不展示（避免子串噪声）
    static func decompose(
        word: String, aliases: [RootAlias]
    ) -> [DictionaryEnrichment.RootPart] {
        let lower = word.lowercased()
        guard lower.allSatisfy({ $0.isLetter }), lower.count >= 4 else { return [] }

        func longestMatch(_ s: String, kind: RootAlias.Kind, atStart: Bool) -> RootAlias? {
            aliases
                .filter { $0.kind == kind && $0.alias.count >= 2 }
                .filter { atStart ? s.hasPrefix($0.alias) : s.hasSuffix($0.alias) }
               .max { $0.alias.count < $1.alias.count }
        }

        var middle = lower
        var parts: [RootAlias] = []
        if let prefix = longestMatch(middle, kind: .prefix, atStart: true),
            middle.count - prefix.alias.count >= 3 {
            parts.append(prefix)
            middle.removeFirst(prefix.alias.count)
        }
        if let suffix = longestMatch(middle, kind: .suffix, atStart: false),
            middle.count - suffix.alias.count >= 3 {
            parts.append(suffix)
            middle.removeLast(suffix.alias.count)
        }

        // 中段贪心扫词根：每个位置取最长匹配，找不到前进一位
        var found: [RootAlias] = []
        var index = middle.startIndex
        while index < middle.endIndex {
            let rest = String(middle[index...])
            if let root = aliases
                .filter({ $0.kind == .root && $0.alias.count >= 3 && rest.hasPrefix($0.alias) })
                .max(by: { $0.alias.count < $1.alias.count }) {
                found.append(root)
                index = middle.index(index, offsetBy: root.alias.count, limitedBy: middle.endIndex) ?? middle.endIndex
            } else if let next = middle.index(index, offsetBy: 1, limitedBy: middle.endIndex), next < middle.endIndex {
                index = next
            } else {
                break
            }
        }
        guard !found.isEmpty else { return [] }
        parts.append(contentsOf: found)

        // 按词内顺序输出（前缀 → 词根 → 后缀）
        let ordered = parts.sorted { a, b in
            let ia = lower.range(of: a.alias)?.lowerBound ?? lower.startIndex
            let ib = lower.range(of: b.alias)?.lowerBound ?? lower.startIndex
            return ia < ib
        }
        return ordered.map { DictionaryEnrichment.RootPart(
            key: $0.key, meaning: $0.meaning, origin: $0.origin,
            examples: $0.examples, direct: false
        ) }
    }

    /// exchange → 词形家族（d过去式 p过去分词 i现在分词 3第三人称 s复数 r比较级 t最高级）
    static func familyForms(of entry: DictionaryEntry) -> [(label: String, form: String)] {
        let labels = ["d": "过去式", "p": "过去分词", "i": "现在分词",
                      "3": "第三人称", "s": "复数", "r": "比较级", "t": "最高级"]
        var seen = Set<String>()
        var result: [(String, String)] = []
        for part in entry.exchange.split(separator: "/") {
            let pieces = part.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  let label = labels[String(pieces[0])] else { continue }
            let form = String(pieces[1])
            guard !form.isEmpty,
                  form.caseInsensitiveCompare(entry.word) != .orderedSame,
                  seen.insert(form.lowercased()).inserted else { continue }
            result.append((label, form))
        }
        return result
    }

    /// 包含该词的常用短语（短语短者优先，排除词条本身）
    private func phrases(
        containing word: String, in dbQueue: DatabaseQueue
    ) -> [String] {
        var rows: [String] = []
        _ = try? dbQueue.read { db in
            rows = try String.fetchAll(
                db,
                sql: """
                    SELECT word FROM dictionary
                    WHERE (word LIKE ? OR word LIKE ? OR word LIKE ?)
                      AND word <> ? COLLATE NOCASE
                    ORDER BY LENGTH(word) LIMIT 5
                    """,
                arguments: ["\(word) %", "% \(word)", "% \(word) %", word]
            )
        }
        return rows
    }

    /// 英英同义词（词条无则试原形）
    private func synonyms(
        for word: String, in dbQueue: DatabaseQueue
    ) -> [String]? {
        var value: String?
        _ = try? dbQueue.read { db in
            value = try String.fetchOne(
                db, sql: "SELECT synonyms FROM thesaurus WHERE word = ? COLLATE NOCASE",
                arguments: [word]
            )
        }
        return value.map { $0.components(separatedBy: ",") }
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
