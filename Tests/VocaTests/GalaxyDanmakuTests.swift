// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
// General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import XCTest
@testable import Voca

@MainActor
final class GalaxyDanmakuTests: XCTestCase {
    private func clip(_ id: Int64, _ text: String) -> Clip {
        Clip(
            id: id, text: text, note: nil, appName: nil, appBundleID: nil,
            wordCount: 1, createdAt: .now, url: nil, count: 1,
            lastSeenAt: .now, textHash: Clip.textHash(of: text)
        )
    }

    func testChangingQueryReplacesVisibleWordsAndHitTargets() {
        let engine = DanmakuEngine()
        let alpha = clip(1, "alpha")
        let beta = clip(2, "beta")
        let size = CGSize(width: 900, height: 420)
        let time = Date()
        engine.update(date: time, size: size, clips: [alpha, beta], query: "",
                      fontBase: 20, fontScale: 1, slowDown: false, reduceMotion: true)
        XCTAssertEqual(Set(engine.words.map(\.clipId)), [1, 2])

        engine.update(date: time.addingTimeInterval(0.016), size: size, clips: [beta], query: "bet",
                      fontBase: 20, fontScale: 1, slowDown: false, reduceMotion: true)
        XCTAssertEqual(engine.words.map(\.clipId), [2])
        let word = engine.words[0]
        let center = engine.laneCenter(word.row)
        XCTAssertNotNil(engine.entry(at: CGPoint(x: word.x + word.chipWidth / 2, y: center)))
        XCTAssertNil(engine.entry(at: CGPoint(x: word.x + word.chipWidth / 2, y: 0)))

        engine.update(date: time.addingTimeInterval(0.032), size: size, clips: [], query: "none",
                      fontBase: 20, fontScale: 1, slowDown: false, reduceMotion: true)
        XCTAssertTrue(engine.words.isEmpty)
    }

    func testFewResultsUseSeparatedMiddleLanes() {
        XCTAssertEqual(DanmakuEngine.activeLanes(itemCount: 0, laneCount: 12), [])
        XCTAssertEqual(DanmakuEngine.activeLanes(itemCount: 1, laneCount: 7), [3])
        XCTAssertEqual(DanmakuEngine.activeLanes(itemCount: 2, laneCount: 8), [2, 6])
        XCTAssertEqual(DanmakuEngine.activeLanes(itemCount: 8, laneCount: 3), [0, 1, 2])
    }
}
