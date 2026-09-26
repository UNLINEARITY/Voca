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
@testable import Voca

/// 查词浮窗「原文入库 + 译文进备注」的合并语义
final class StoreSaveNoteTests: XCTestCase {
    private var store: ClipStore!
    private var dbURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voca-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("voca.sqlite")
        store = try ClipStore(url: dbURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    func testSaveWithNoteSetsNote() throws {
        let clip = try store.save(
            text: "race condition", appName: nil, bundleID: nil,
            note: "竞态条件"
        )
        XCTAssertEqual(clip.note, "竞态条件")
        XCTAssertEqual(clip.count, 1)
    }

    func testMergeAdoptsNewestNonNilNote() throws {
        _ = try store.save(text: "race condition", appName: nil, bundleID: nil, note: "竞态")
        let merged = try store.save(
            text: "race condition", appName: nil, bundleID: nil, note: "竞态条件"
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.note, "竞态条件")

        // nil/空备注不覆盖既有备注
        let preserved = try store.save(text: "race condition", appName: nil, bundleID: nil)
        XCTAssertEqual(preserved.count, 3)
        XCTAssertEqual(preserved.note, "竞态条件")
    }

    func testSaveWithoutNoteKeepsNil() throws {
        let clip = try store.save(text: "hello", appName: nil, bundleID: nil)
        XCTAssertNil(clip.note)
    }
}
