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
import SwiftUI

/// 检索档全屏词库弹幕：词条从左缘向右缘漂移，多行循环展示整个词库。
/// 输入关键词后命中词高亮、未命中词淡出；悬停整屏减速，单击选中（下方信息卡），
/// 双击打开查词浮窗。Canvas + TimelineView 逐帧绘制，只绘屏内词条。
struct GalaxyDanmakuView: View {
    @ObservedObject var model: GalaxyModel
    let clips: [Clip]
    /// 星图界面字号基准（设置页「星图界面字号」），弹幕字号在其上 +2
    let chromeBase: Double
    var reduceMotion = false
    var onSelect: (GalaxyItem) -> Void
    var onLookup: (GalaxyEntry) -> Void

    @State private var engine = DanmakuEngine()
    @State private var pointer: CGPoint?
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let fontBase = Typography.derived(chromeBase, offset: 4)
                    * CGFloat(model.fontScale)
                engine.update(
                    date: timeline.date,
                    size: size,
                    clips: clips,
                    query: model.searchQuery,
                    fontBase: fontBase,
                    fontScale: model.fontScale,
                    slowDown: hovering,
                    reduceMotion: reduceMotion
                )
                draw(
                    context: context,
                    size: size,
                    query: model.searchQuery,
                    fontBase: fontBase
                )
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer = location
                hovering = true
            case .ended:
                hovering = false
                pointer = nil
            @unknown default:
                break
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in
                if let entry = engine.entry(at: value.location) {
                    onLookup(entry)
                }
            }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 1).onEnded { value in
                if let entry = engine.entry(at: value.location) {
                    let clipId: Int64
                    switch entry {
                    case .library(let clip): clipId = clip.id ?? 0
                    case .clipboard: clipId = 0
                    }
                    onSelect(
                        GalaxyItem(
                            clipId: clipId,
                            text: GalaxyModel.displayText(entry.text),
                            fontSize: 25,
                            entry: entry,
                            position: .zero
                        )
                    )
                }
            }
        )
    }

    private func draw(
        context: GraphicsContext, size: CGSize, query: String, fontBase: CGFloat
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for word in engine.words {
            let isMatch = !trimmed.isEmpty && word.text.localizedCaseInsensitiveContains(trimmed)
            let isSelected = model.selectedItem?.clipId == word.clipId
            let isHovered = pointer.map { engine.entry(at: $0)?.text == word.entry.text } ?? false
            let dimmed = !trimmed.isEmpty && !isMatch && !isSelected
            let chipAlpha: CGFloat = dimmed ? 0.35 : 1

            // 深色玻璃底胶囊：半透明暗底 + 白细描边 + 顶部高光线，保证任意壁纸上可读
            let laneCenter = engine.laneCenter(word.row)
            let chipRect = CGRect(
                x: word.x,
                y: laneCenter - word.chipHeight / 2,
                width: word.chipWidth,
                height: word.chipHeight
            )
            let chip = Path(roundedRect: chipRect, cornerRadius: word.chipHeight / 2)
            context.fill(chip, with: .color(.black.opacity(0.55 * chipAlpha)))
            let borderColor: Color = isSelected
                ? .accentColor.opacity(0.95)
                : isHovered
                    ? .white.opacity(0.65 * chipAlpha)
                    : .white.opacity(0.35 * chipAlpha)
            context.stroke(chip, with: .color(borderColor), lineWidth: 1)
            let sheen = CGRect(
                x: chipRect.minX + DanmakuEngine.Word.chipPadX,
                y: chipRect.minY + 2,
                width: min(word.width * 0.5, chipRect.width * 0.4),
                height: 1
            )
            context.fill(Path(sheen), with: .color(.white.opacity(0.35 * chipAlpha)))

            let textColor: Color = isMatch ? .accentColor : .white
            let textOpacity: CGFloat = dimmed ? 0.55 : 1
            context.draw(
                Text(word.text)
                    .font(.system(size: word.fontSize, weight: isMatch ? .semibold : .regular))
                    .foregroundColor(textColor.opacity(textOpacity)),
                at: CGPoint(
                    x: word.x + DanmakuEngine.Word.chipPadX + word.width / 2,
                    y: laneCenter
                ),
                anchor: .center
            )
        }
    }
}

/// 弹幕流引擎：按行调度词条生成与漂移，维护虚拟时钟以支持整屏减速。
@MainActor
private final class DanmakuEngine {
    struct Word {
        let id: Int64
        let clipId: Int64
        let entry: GalaxyEntry
        let text: String
        var width: CGFloat
        var fontSize: CGFloat
        let row: Int
        var speed: CGFloat
        var x: CGFloat

        static let chipPadX: CGFloat = 10
        var chipWidth: CGFloat { width + Self.chipPadX * 2 }
        var chipHeight: CGFloat { fontSize + 14 }
    }

    private(set) var words: [Word] = []

    private static let gap: CGFloat = 110
    private static let topInset: CGFloat = 74
    private static let bottomInset: CGFloat = 130

    private var deck: [GalaxyEntry] = []
    private var deckSignature = ""
    private var lastByLane: [Int: Int64] = [:]
    private var laneCount = 0
    private var laneGeometry = CGSize.zero
    private var fontBase: CGFloat = 0
    private var widthCache: [String: CGFloat] = [:]
    private var lastDate: Date?
    private var timeScale: CGFloat = 1
    private var nextWordID: Int64 = 1

    /// 词条字号：基准随保存次数增长（每多 1 次 +2.5pt，封顶 +12），并夹在行高内
    private func fontSize(
        forCount count: Int, fontBase: CGFloat, laneHeight: CGFloat
    ) -> CGFloat {
        min(
            fontBase + CGFloat(max(count - 1, 0)) * 2.5,
            min(fontBase + 12, laneHeight - 22)
        )
    }

    private func makeWord(
        _ entry: GalaxyEntry, row: Int, x: CGFloat, fontBase: CGFloat, laneHeight: CGFloat,
        clips: [Clip]
    ) -> Word? {
        let count: Int
        switch entry {
        case .library(let clip): count = clip.count
        case .clipboard: count = 1
        }
        let size = fontSize(forCount: count, fontBase: fontBase, laneHeight: laneHeight)
        let text = GalaxyModel.displayText(entry.text)
        guard !text.isEmpty else { return nil }
        let width = measuredWidth(text, font: size)
        defer { nextWordID += 1 }
        return Word(
            id: nextWordID,
            clipId: clipID(of: entry),
            entry: entry,
            text: text,
            width: width,
            fontSize: size,
            row: row,
            speed: .random(in: 60...105),
            x: x
        )
    }

    func update(
        date: Date,
        size: CGSize,
        clips: [Clip],
        query: String,
        fontBase: CGFloat,
        fontScale: Double,
        slowDown: Bool,
        reduceMotion: Bool
    ) {
        var delta: CGFloat = 0
        if let lastDate {
            delta = min(0.1, max(0, CGFloat(date.timeIntervalSince(lastDate))))
        }
        lastDate = date

        let signature = "\(clips.count):\(clips.first?.id ?? -1):\(clips.first?.lastSeenAt.timeIntervalSince1970 ?? 0)"
        let windowChanged = laneCount == 0 || abs(laneGeometry.width - size.width) > 1
            || abs(laneGeometry.height - size.height) > 1
        let newLaneCount = Self.laneCount(size: size, fontScale: fontScale)
        let lanesChanged = laneCount != 0 && newLaneCount != laneCount
        let fontChanged = self.fontBase != fontBase
        if windowChanged || lanesChanged {
            // 窗口尺寸或行数变化：整流重铺
            laneGeometry = size
            laneCount = newLaneCount
            self.fontBase = fontBase
            widthCache = [:]
            lastByLane = [:]
            prefill(size: size, clips: clips)
            rebuildDeck(clips: clips)
        } else if fontChanged {
            // 字号缩放：整流按比例平滑缩放（位置/速度/宽度同步），不重铺
            let ratio = fontBase / max(self.fontBase, 1)
            self.fontBase = fontBase
            rescale(ratio: ratio)
        } else if signature != deckSignature {
            deckSignature = signature
            rebuildDeck(clips: clips)
        }

        let target: CGFloat = reduceMotion ? 0 : (slowDown ? 0.12 : 1)
        timeScale += (target - timeScale) * min(1, delta * 8)

        // 移动并移除飘出右缘的词条
        var moved: [Word] = []
        moved.reserveCapacity(words.count)
        for var word in words {
            word.x += word.speed * delta * timeScale
            if word.x < size.width + 10 {
                moved.append(word)
            } else if lastByLane[word.row] == word.id {
                lastByLane[word.row] = nil
            }
        }
        words = moved

        // 逐行补充：上一词条（队尾）左缘越过 gap 后，从牌堆取下一个词从左缘进场
        for lane in 0..<laneCount {
            let ready: Bool
            if let lastID = lastByLane[lane], let prev = words.first(where: { $0.id == lastID }) {
                ready = prev.x >= Self.gap
            } else {
                ready = true
            }
            if ready {
                spawn(lane: lane, clips: clips)
            }
        }
    }

    func laneCenter(_ row: Int) -> CGFloat {
        let height = laneGeometry.height - Self.topInset - Self.bottomInset
        return Self.topInset + height * (CGFloat(row) + 0.5) / CGFloat(max(laneCount, 1))
    }

    private static func laneCount(size: CGSize, fontScale: Double) -> Int {
        let available = size.height - Self.topInset - Self.bottomInset
        let rowHeight = 56 * max(fontScale, 0.5)
        return max(3, min(12, Int(available / rowHeight)))
    }

    /// 字号变化时整流等比缩放：位置、速度、宽度、胶囊尺寸同步，行中心不变
    private func rescale(ratio: CGFloat) {
        let laneHeight = (laneGeometry.height - Self.topInset - Self.bottomInset)
            / CGFloat(max(laneCount, 1))
        words = words.map { word in
            var scaled = word
            scaled.fontSize = min(word.fontSize * ratio, laneHeight - 20)
            scaled.width = measuredWidth(word.text, font: scaled.fontSize)
            scaled.x *= ratio
            scaled.speed *= ratio
            return scaled
        }
    }

    func entry(at point: CGPoint) -> GalaxyEntry? {
        words.first { word in
            point.x >= word.x && point.x <= word.x + word.chipWidth
                && abs(point.y - laneCenter(word.row)) <= word.chipHeight / 2
        }?.entry
    }

    /// 开场即满屏：按行预铺词条（随机相位），避免进入检索档后干等词条从左缘飘入
    private func prefill(size: CGSize, clips: [Clip]) {
        words = []
        let laneHeight = (size.height - Self.topInset - Self.bottomInset) / CGFloat(max(laneCount, 1))
        for lane in 0..<laneCount {
            var x = -CGFloat.random(in: 0...(size.width * 0.4))
            var rearID: Int64?
            while x < size.width {
                guard let entry = takeNext(clips: clips),
                      let word = makeWord(
                          entry, row: lane, x: x, fontBase: fontBase,
                          laneHeight: laneHeight, clips: clips
                      )
                else { break }
                words.append(word)
                rearID = word.id
                x += word.chipWidth + Self.gap
            }
            if let rearID {
                lastByLane[lane] = rearID
            }
        }
    }

    private func spawn(lane: Int, clips: [Clip]) {
        // 屏内去重：同一词条不重复出现
        for _ in 0..<5 {
            guard let entry = takeNext(clips: clips) else { return }
            if words.contains(where: { $0.clipId == clipID(of: entry) }) { continue }
            let laneHeight = (laneGeometry.height - Self.topInset - Self.bottomInset)
                / CGFloat(max(laneCount, 1))
            guard let word = makeWord(
                entry, row: lane, x: 0, fontBase: fontBase,
                laneHeight: laneHeight, clips: clips
            ) else { continue }
            var spawned = word
            spawned.x = -word.chipWidth
            words.append(spawned)
            lastByLane[lane] = spawned.id
            return
        }
    }

    /// 牌堆：最近保存的 24 条洗牌后优先进场；每词条一次循环仅出现一次（频次改由字号体现）
    private func takeNext(clips: [Clip]) -> GalaxyEntry? {
        if deck.isEmpty {
            rebuildDeck(clips: clips)
        }
        guard !deck.isEmpty else { return nil }
        return deck.removeFirst()
    }

    private func rebuildDeck(clips: [Clip]) {
        let sorted = clips.sorted { $0.lastSeenAt > $1.lastSeenAt }
        deck = sorted.prefix(24).shuffled().map(GalaxyEntry.library)
            + sorted.dropFirst(24).shuffled().map(GalaxyEntry.library)
    }

    private func measuredWidth(_ text: String, font: CGFloat) -> CGFloat {
        let key = "\(Int(font.rounded()))|\(text)"
        if let cached = widthCache[key] { return cached }
        let size = (text as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: font)]
        )
        widthCache[key] = size.width
        return size.width
    }

    private func clipID(of entry: GalaxyEntry) -> Int64 {
        switch entry {
        case .library(let clip): clip.id ?? 0
        case .clipboard: 0
        }
    }
}
