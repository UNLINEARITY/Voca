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

import XCTest
@testable import Voca

@MainActor
final class GalaxyTimeWallTests: XCTestCase {
    private func clip(
        _ id: Int64, _ text: String, daysAgo: Double, count: Int = 1, at: Date? = nil
    ) -> Clip {
        Clip(
            id: id, text: text, note: nil, appName: nil, appBundleID: nil,
            wordCount: 1, createdAt: .now, url: nil, count: count,
            lastSeenAt: at ?? .now.addingTimeInterval(-daysAgo * 86400),
            textHash: Clip.textHash(of: text)
        )
    }

    private func layout(_ clips: [Clip]) -> TimeWallLayout.Result {
        TimeWallLayout.layout(
            clips: clips,
            canvasSize: CGSize(width: 1000, height: 500),
            fontBase: 17,
            scale: 1,
            offset: 0
        )
    }

    func testOlderEntriesSitLeftAndBlockCenters() {
        let result = layout([
            clip(1, "older word", daysAgo: 30),
            clip(2, "newer word", daysAgo: 1),
        ])
        XCTAssertEqual(result.words.count, 2)
        let older = result.words.first { $0.clipId == 1 }
        let newer = result.words.first { $0.clipId == 2 }
        XCTAssertNotNil(older)
        XCTAssertNotNil(newer)
        XCTAssertLessThan(older!.centerX, newer!.centerX)
        // 整块居中：左右留白对称
        let leftEdge = older!.centerX - older!.chipWidth / 2
        let rightEdge = newer!.centerX + newer!.chipWidth / 2
        XCTAssertEqual((leftEdge + rightEdge) / 2, 500, accuracy: 2)
    }

    func testIdleGapsAreCapped() {
        // 14 天间隔 vs 300 天间隔：封顶后像素距离应一致
        let shortGap = layout([
            clip(1, "alpha", daysAgo: 14), clip(2, "beta", daysAgo: 0),
        ]).words
        let longGap = layout([
            clip(1, "alpha", daysAgo: 300), clip(2, "beta", daysAgo: 0),
        ]).words
        let shortDistance = shortGap[1].centerX - shortGap[0].centerX
        let longDistance = longGap[1].centerX - longGap[0].centerX
        XCTAssertEqual(shortDistance, longDistance, accuracy: 1)
        // 300 天的空档不得撑爆画布
        XCTAssertLessThan(longDistance, 1000)
    }

    func testOverlappingEntriesStackIntoDifferentRows() {
        // 同一时刻的三个长词条（截断后 460pt 宽）完全重叠，应分到三行
        let same = Date(timeIntervalSinceNow: -3600)
        let result = layout([
            clip(1, String(repeating: "long ", count: 40), daysAgo: 0, at: same),
            clip(2, String(repeating: "long ", count: 40), daysAgo: 0, at: same),
            clip(3, String(repeating: "long ", count: 40), daysAgo: 0, at: same),
        ])
        XCTAssertEqual(result.words.count, 3)
        let rows = Set(result.words.map(\.row))
        XCTAssertEqual(rows.count, 3, "同位置的三个长词条应分到三行")
    }

    func testDenseEntriesWidenAxisInsteadOfShrinkingFont() {
        // 大量同刻长句：字号不得被压缩，时间轴应拉宽溢出屏幕
        let clips = (0..<60).map {
            clip(Int64($0), String(repeating: "word ", count: 20), daysAgo: Double($0) / 1000)
        }
        let result = TimeWallLayout.layout(
            clips: clips,
            canvasSize: CGSize(width: 1000, height: 500),
            fontBase: 17,
            scale: 1,
            offset: 0
        )
        XCTAssertEqual(result.words.count, 60)
        XCTAssertGreaterThan(result.contentWidth, 1000, "密集内容应拉宽时间轴而非压缩")
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.fontSize, 17, "字号不得低于基准")
        }
    }

    func testPanClampsToContentEdgesIncludingChipWidth() {
        // 内容溢出：平移边界按实际边缘（含胶囊半宽、两侧 24pt 边距）计算
        // 正向 1124 = 看到最旧（左）端；负向 -924 = 看到最新（右）端
        let model = GalaxyModel()
        model.timeWallEdges = (min: -1600, max: 1400)
        model.panTimeWall(by: 5000, canvasWidth: 1000)
        XCTAssertEqual(model.timeWallOffset, 1124, accuracy: 2)
        model.panTimeWall(by: -99999, canvasWidth: 1000)
        XCTAssertEqual(model.timeWallOffset, -924, accuracy: 2)

        // 内容不溢出：固定居中不可滑
        model.timeWallEdges = (min: -300, max: 300)
        model.panTimeWall(by: 300, canvasWidth: 1000)
        XCTAssertEqual(model.timeWallOffset, 0)
    }

    func testFrequencyGrowsFontSize() {
        let result = layout([
            clip(1, "rare", daysAgo: 10, count: 1),
            clip(2, "frequent", daysAgo: 9, count: 6),
        ])
        let rare = result.words.first { $0.clipId == 1 }
        let frequent = result.words.first { $0.clipId == 2 }
        XCTAssertGreaterThan(frequent!.fontSize, rare!.fontSize + 5)
    }

    func testLongTextIsTruncatedWithEllipsis() {
        let long = String(repeating: "很长的一句话 ", count: 60)
        let result = layout([clip(1, long, daysAgo: 5)])
        let word = result.words[0]
        XCTAssertTrue(word.text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(word.chipWidth, TimeWallLayout.maxTextWidth + 20 + 2)
        XCTAssertGreaterThan(word.chipWidth, 100)
    }

    func testHitTestMatchesChipBoundsOnly() {
        let result = layout([
            clip(1, "target", daysAgo: 5),
        ])
        let word = result.words[0]
        let hit = TimeWallLayout.entry(
            at: CGPoint(x: word.centerX, y: word.centerY), in: result
        )
        let miss = TimeWallLayout.entry(
            at: CGPoint(x: word.centerX, y: 470), in: result
        )
        XCTAssertNotNil(hit)
        XCTAssertNil(miss)
    }

    func testZoomClampsToExpandedRange() {
        let model = GalaxyModel()
        model.zoomTimeWall(by: 0.001, anchorX: nil, canvasWidth: nil)
        XCTAssertEqual(model.timeWallScale, TimeWallLayout.minScale)
        model.zoomTimeWall(by: 100, anchorX: nil, canvasWidth: nil)
        XCTAssertEqual(model.timeWallScale, TimeWallLayout.maxScale)
        model.zoomTimeWall(by: 0.5, anchorX: nil, canvasWidth: nil)
        XCTAssertEqual(model.timeWallScale, 4, accuracy: 0.0001)
    }

    func testTickGranularityFollowsVisibleSpan() {
        let day = 86400.0
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 2 * day), .hour)
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 13 * day), .day)
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 15 * day), .month)
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 91 * day), .quarter)
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 361 * day), .quarter)
        XCTAssertEqual(TimeWallLayout.TickGranularity.pick(forVisibleSpan: 541 * day), .year)
        XCTAssertEqual(TimeWallLayout.TickGranularity.year.formatTemplate, "y")
        XCTAssertEqual(TimeWallLayout.TickGranularity.quarter.minorStep.month, 1)
    }

    func testZoomedOutDenseWallFitsOnScreen() {
        // 几天内的稠密数据：缩到最小时整条时间线一屏可见，行数不超出屏高
        let clips = (0..<80).map { index in
            clip(Int64(index), "word\(index)", daysAgo: Double(index) * 0.04)
        }
        let result = TimeWallLayout.layout(
            clips: clips, canvasSize: CGSize(width: 1000, height: 500),
            fontBase: 17, scale: TimeWallLayout.minScale, offset: 0
        )
        XCTAssertEqual(result.words.count, 80)
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.centerX, 0)
            XCTAssertLessThanOrEqual(word.centerX, 1000)
        }
        let rowHeight: CGFloat = 17 + 14
        let maxRows = max(1, Int(500 - 48) / Int(rowHeight))
        XCTAssertLessThanOrEqual((result.words.map(\.row).max() ?? 0) + 1, maxRows)
        XCTAssertFalse(result.ticks.isEmpty)
    }

    func testZoomedOutWallStillDrawsTicks() {
        let clips = [
            clip(1, "alpha", daysAgo: 800),
            clip(2, "beta", daysAgo: 400),
            clip(3, "gamma", daysAgo: 1),
        ]
        for scale in [TimeWallLayout.minScale, 1.0] {
            let result = TimeWallLayout.layout(
                clips: clips, canvasSize: CGSize(width: 1000, height: 500),
                fontBase: 17, scale: scale, offset: 0
            )
            XCTAssertFalse(result.ticks.isEmpty, "ticks missing at scale \(scale)")
        }
    }
}
