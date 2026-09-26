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

import XCTest
import GRDB
@testable import Voca

final class DictionaryServiceTests: XCTestCase {
    private var service: DictionaryService!
    private var dbURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voca-dict-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("dictionary.sqlite")

        // 与 scripts/make_dictionary.py 相同的最小 schema + 覆盖查询链的样本词条
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary (
                    word TEXT PRIMARY KEY COLLATE NOCASE,
                    phonetic TEXT NOT NULL DEFAULT '',
                    translation TEXT NOT NULL DEFAULT '',
                    definition TEXT NOT NULL DEFAULT '',
                    exchange TEXT NOT NULL DEFAULT '',
                    tag TEXT NOT NULL DEFAULT '',
                    collins INTEGER NOT NULL DEFAULT 0,
                    oxford INTEGER NOT NULL DEFAULT 0,
                    bnc INTEGER NOT NULL DEFAULT 0,
                    frq INTEGER NOT NULL DEFAULT 0
                )
                """)
            let rows: [[(String, DatabaseValueConvertible)]] = [
                [("word", "go"), ("phonetic", "gәu"), ("translation", "vi. 去"),
                 ("definition", "v. to move"), ("exchange", "d:went/p:gone/0:go/1:d"),
                 ("tag", "zk gk"), ("collins", 5), ("oxford", 1), ("frq", 300)],
                [("word", "went"), ("phonetic", "went"), ("translation", "go的过去式"),
                 ("exchange", "0:go/1:p")],
                [("word", "serendipity"), ("phonetic", ",serәn'dipiti"),
                 ("translation", "n. 偶然发现珍宝的运气"), ("frq", 23199)],
                [("word", "well-known"), ("translation", "a. 著名的")],
            ]
            for row in rows {
                let columns = row.map(\.0).joined(separator: ", ")
                let placeholders = row.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "INSERT INTO dictionary (\(columns)) VALUES (\(placeholders))",
                    arguments: StatementArguments(row.map(\.1))
                )
            }
        }
        service = DictionaryService(url: dbURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // MARK: - 查询

    func testExactLookup() {
        let result = service.lookup("go")
        XCTAssertEqual(result?.entry.word, "go")
        XCTAssertEqual(result?.entry.collins, 5)
        XCTAssertNil(result?.lemma)  // go 自身是原形（exchange 指向自己）
    }

    func testCaseInsensitiveLookup() {
        XCTAssertEqual(service.lookup("Serendipity")?.entry.word, "serendipity")
        XCTAssertEqual(service.lookup("GO")?.entry.translation, "vi. 去")
    }

    func testPunctuationAndPossessiveNormalization() {
        XCTAssertEqual(service.lookup("\"go.\"")?.entry.word, "go")
        XCTAssertEqual(service.lookup("go's")?.entry.word, "go")
        XCTAssertEqual(service.lookup("’go’")?.entry.word, "go")
    }

    func testInflectedFormResolvesLemma() {
        let result = service.lookup("went")
        XCTAssertEqual(result?.entry.word, "went")
        XCTAssertEqual(result?.entry.translation, "go的过去式")
        XCTAssertEqual(result?.lemma?.word, "go")
    }

    func testHyphenatedWordLookup() {
        XCTAssertEqual(service.lookup("well-known")?.entry.word, "well-known")
    }

    func testMissReturnsNil() {
        XCTAssertNil(service.lookup("nonexistentword"))
        XCTAssertNil(service.lookup(""))
        XCTAssertNil(service.lookup("  "))
    }

    func testMissingDatabaseReturnsNil() {
        let empty = DictionaryService(url: nil)
        XCTAssertNil(empty.lookup("go"))
    }

    // MARK: - 单词判定

    func testIsTranslatable() {
        XCTAssertTrue(DictionaryService.isTranslatable("hello"))
        XCTAssertTrue(DictionaryService.isTranslatable("look forward to"))
        XCTAssertTrue(DictionaryService.isTranslatable("The quick brown fox!"))
        XCTAssertTrue(DictionaryService.isTranslatable("美丽"))
        XCTAssertFalse(DictionaryService.isTranslatable(""))
        XCTAssertFalse(DictionaryService.isTranslatable("123"))
        XCTAssertFalse(DictionaryService.isTranslatable(String(repeating: "a", count: 501)))
    }

    func testContainsCJK() {
        XCTAssertTrue(DictionaryService.containsCJK("美丽"))
        XCTAssertTrue(DictionaryService.containsCJK("hello 世界"))
        XCTAssertFalse(DictionaryService.containsCJK("hello"))
    }

    // MARK: - 展示格式化

    func testPhoneticPrettify() {
        XCTAssertEqual(
            DictionaryService.prettifiedPhonetic("hә'lәu"),
            "/hə'ləu/"
        )
        XCTAssertEqual(
            DictionaryService.prettifiedPhonetic("ki:"),
            "/kiː/"
        )
        XCTAssertEqual(DictionaryService.prettifiedPhonetic(""), "")
    }

    func testDisplayTextConvertsLiteralNewlines() {
        XCTAssertEqual(
            DictionaryService.displayText("n. 苹果\\n[医] 苹果"),
            "n. 苹果\n[医] 苹果"
        )
    }

    func testLocalizedTags() {
        XCTAssertEqual(
            DictionaryService.localizedTags("zk gk cet4 unknown"),
            ["中考", "高考", "四级", "unknown"]
        )
    }
}

// MARK: - 查词入口决策与浮窗定位

final class LookupPopupLogicTests: XCTestCase {
    private var service: DictionaryService!
    private var dbURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voca-lookup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("dictionary.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary (
                    word TEXT PRIMARY KEY COLLATE NOCASE,
                    phonetic TEXT NOT NULL DEFAULT '',
                    translation TEXT NOT NULL DEFAULT '',
                    definition TEXT NOT NULL DEFAULT '',
                    exchange TEXT NOT NULL DEFAULT '',
                    tag TEXT NOT NULL DEFAULT '',
                    collins INTEGER NOT NULL DEFAULT 0,
                    oxford INTEGER NOT NULL DEFAULT 0,
                    bnc INTEGER NOT NULL DEFAULT 0,
                    frq INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(
                sql: "INSERT INTO dictionary (word, translation) VALUES ('go', 'vi. 去')"
            )
        }
        service = DictionaryService(url: dbURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    func testOutcomeIgnoresUntranslatableInput() {
        // 空、纯数字、超长 → 静默忽略
        XCTAssertEqual(LookupPopupController.outcome(for: "", service: service), .ignored)
        XCTAssertEqual(LookupPopupController.outcome(for: "123", service: service), .ignored)
        XCTAssertEqual(
            LookupPopupController.outcome(for: String(repeating: "a", count: 501), service: service),
            .ignored
        )
    }

    func testOutcomeShowsDictionaryHit() {
        if case .card(let result) = LookupPopupController.outcome(for: "\"Go.\"", service: service) {
            XCTAssertEqual(result.entry.word, "go")
        } else {
            XCTFail("应命中 go")
        }
    }

    func testOutcomeFallsBackToTranslation() {
        // 词典未命中的英文句子 → 翻译（英→中）
        if case .translate(let text, let direction) = LookupPopupController.outcome(
            for: "i like apples", service: service
        ) {
            XCTAssertEqual(text, "i like apples")
            XCTAssertEqual(direction, .englishToChinese)
        } else {
            XCTFail("应走翻译")
        }
        // 中文 → 翻译（中→英）
        if case .translate(_, let direction) = LookupPopupController.outcome(
            for: "今天天气不错", service: service
        ) {
            XCTAssertEqual(direction, .chineseToEnglish)
        } else {
            XCTFail("中文应走翻译")
        }
    }

    // MARK: 浮窗定位

    private let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)

    func testPopupFrameSitsAboveCursor() {
        let frame = LookupPopupController.popupFrame(
            cursor: CGPoint(x: 500, y: 400),
            size: CGSize(width: 400, height: 200),
            visibleFrame: visible
        )
        XCTAssertEqual(frame.minY, 418, accuracy: 0.01)
        XCTAssertEqual(frame.midX, 500, accuracy: 0.01)
    }

    func testPopupFrameFlipsBelowWhenNoRoomAbove() {
        let frame = LookupPopupController.popupFrame(
            cursor: CGPoint(x: 500, y: 750),
            size: CGSize(width: 400, height: 200),
            visibleFrame: visible
        )
        XCTAssertEqual(frame.maxY, 732, accuracy: 0.01)
    }

    func testPopupFrameClampsHorizontally() {
        let nearLeft = LookupPopupController.popupFrame(
            cursor: CGPoint(x: 30, y: 400),
            size: CGSize(width: 400, height: 200),
            visibleFrame: visible
        )
        XCTAssertEqual(nearLeft.minX, 6, accuracy: 0.01)
        let nearRight = LookupPopupController.popupFrame(
            cursor: CGPoint(x: 980, y: 400),
            size: CGSize(width: 400, height: 200),
            visibleFrame: visible
        )
        XCTAssertEqual(nearRight.maxX, 994, accuracy: 0.01)
    }
}
