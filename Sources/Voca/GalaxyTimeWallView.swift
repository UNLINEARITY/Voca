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

/// 检索档静态时间词墙：词条按真实保存时间横向定位（旧左新右，空档封顶），
/// 垂直自动避让叠行、整体居中；捏合缩放时间轴、双指左右滑动浏览、
/// 双击空白复位；底部日期刻度随缩放自适应粒度。无持续动画，按 state 重绘。
struct GalaxyTimeWallView: View {
    @ObservedObject var model: GalaxyModel
    let clips: [Clip]
    /// 星图界面字号基准（设置页），词墙字号在其上按频次放大
    let chromeBase: Double
    var onSelect: (GalaxyItem) -> Void
    var onLookup: (GalaxyEntry) -> Void

    @State private var pointer: CGPoint?
    @State private var lastDragTranslation: CGSize?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let layout = layout(size: size)
                draw(context: context, size: size, layout: layout)
            }
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): pointer = location
                case .ended: pointer = nil
                @unknown default: break
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    if let entry = TimeWallLayout.entry(at: value.location, in: layout(size: proxy.size)) {
                        onLookup(entry)
                    } else {
                        model.resetTimeWall()
                    }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    guard let entry = TimeWallLayout.entry(
                        at: value.location, in: layout(size: proxy.size)
                    ) else { return }
                    onSelect(
                        GalaxyItem(
                            clipId: TimeWallLayout.clipID(of: entry),
                            text: GalaxyModel.displayText(entry.text),
                            fontSize: 25,
                            entry: entry,
                            position: .zero
                        )
                    )
                }
            )
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let delta = value.translation.width
                            - (lastDragTranslation?.width ?? 0)
                        lastDragTranslation = value.translation
                        guard abs(delta) > 0 else { return }
                        // 内容跟手：手指右移内容右移
                        model.panTimeWall(by: Double(delta), canvasWidth: proxy.size.width)
                    }
                    .onEnded { _ in lastDragTranslation = nil }
            )
        }
    }

    private func layout(size: CGSize) -> TimeWallLayout.Result {
        let result = TimeWallLayout.layout(
            clips: clips,
            canvasSize: size,
            fontBase: Typography.derived(chromeBase, offset: 2) * CGFloat(model.fontScale),
            scale: CGFloat(model.timeWallScale),
            offset: CGFloat(model.timeWallOffset)
        )
        // 回写内容实际边缘供平移边界计算（非发布属性，不触发重绘）
        model.timeWallEdges = (result.minEdge, result.maxEdge)
        return result
    }

    private func draw(
        context: GraphicsContext, size: CGSize, layout: TimeWallLayout.Result
    ) {
        for word in layout.words {
            let isSelected = model.selectedItem?.clipId == word.clipId
            let isHovered = pointer.map { p in
                abs(p.x - word.centerX) <= word.chipWidth / 2
                    && abs(p.y - word.centerY) <= word.chipHeight / 2
            } ?? false

            let chipRect = CGRect(
                x: word.centerX - word.chipWidth / 2,
                y: word.centerY - word.chipHeight / 2,
                width: word.chipWidth,
                height: word.chipHeight
            )
            let chip = Path(roundedRect: chipRect, cornerRadius: word.chipHeight / 2)
            context.fill(chip, with: .color(.black.opacity(0.55)))
            let borderColor: Color = isSelected
                ? .accentColor.opacity(0.95)
                : isHovered ? .white.opacity(0.65) : .white.opacity(0.35)
            context.stroke(chip, with: .color(borderColor), lineWidth: 1)
            let sheen = CGRect(
                x: chipRect.minX + TimeWallLayout.chipPadX,
                y: chipRect.minY + 2,
                width: min(word.width * 0.5, chipRect.width * 0.4),
                height: 1
            )
            context.fill(Path(sheen), with: .color(.white.opacity(0.35)))

            context.draw(
                Text(word.text)
                    .font(.system(size: word.fontSize))
                    .foregroundColor(.white),
                at: CGPoint(x: word.centerX, y: word.centerY),
                anchor: .center
            )
        }

        // 底部时间标尺（表盘感）：基线＋次级短刻度＋主刻度长线＋玻璃胶囊日期
        let baselineY = size.height - 30
        var ruler = Path()
        ruler.move(to: CGPoint(x: 12, y: baselineY))
        ruler.addLine(to: CGPoint(x: size.width - 12, y: baselineY))
        context.stroke(ruler, with: .color(.white.opacity(0.30)), lineWidth: 1)

        for x in layout.minorTicks {
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: baselineY))
            tick.addLine(to: CGPoint(x: x, y: baselineY - 5))
            context.stroke(tick, with: .color(.white.opacity(0.22)), lineWidth: 1)
        }

        let tickCenterY = size.height - 13
        for tick in layout.ticks {
            guard tick.x >= 8, tick.x <= size.width - 8 else { continue }
            var major = Path()
            major.move(to: CGPoint(x: tick.x, y: baselineY))
            major.addLine(to: CGPoint(x: tick.x, y: baselineY - 11))
            context.stroke(major, with: .color(.white.opacity(0.45)), lineWidth: 1)

            let label = context.resolve(
                Text(tick.label)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
            )
            let measured = label.measure(in: CGSize(width: 400, height: 20))
            let chipRect = CGRect(
                x: tick.x - (measured.width + 12) / 2,
                y: tickCenterY - 8,
                width: measured.width + 12,
                height: 16
            )
            let chip = Path(roundedRect: chipRect, cornerRadius: 8)
            context.fill(chip, with: .color(.black.opacity(0.55)))
            context.stroke(chip, with: .color(.white.opacity(0.35)), lineWidth: 1)
            context.draw(label, at: CGPoint(x: tick.x, y: tickCenterY), anchor: .center)
        }
    }
}

/// 时间词墙布局：纯函数，视图与测试共用（displayText 依赖主 actor）。
@MainActor
enum TimeWallLayout {
    struct Word {
        let clipId: Int64
        let entry: GalaxyEntry
        let text: String
        let width: CGFloat
        let fontSize: CGFloat
        let row: Int
        /// 画布坐标系中心
        let centerX: CGFloat
        let centerY: CGFloat

        var chipWidth: CGFloat { width + chipPadX * 2 }
        var chipHeight: CGFloat { fontSize + 14 }
    }

    struct Tick {
        let x: CGFloat
        let label: String
    }

    struct Result {
        let words: [Word]
        let ticks: [Tick]
        /// 次级细分刻度的 x 位置（表盘短刻度，不带标签）
        let minorTicks: [CGFloat]
        let contentWidth: CGFloat
        /// 内容坐标系下的实际边缘（含胶囊半宽），平移边界用
        let minEdge: CGFloat
        let maxEdge: CGFloat
    }

    nonisolated static let chipPadX: CGFloat = 10
    /// 词条胶囊文字最大宽度：超出截断加省略号，全文在选中后的详情卡看
    static let maxTextWidth: CGFloat = 440
    /// 相邻词条时间空档封顶（超过按 14 天计），避免长期未保存产生大片空白
    static let gapCap: TimeInterval = 14 * 86400
    /// 时间轴最大放大倍数
    static let maxScale: Double = 8
    /// 行间水平最小间隙
    private static let rowGap: CGFloat = 8

    static func clipID(of entry: GalaxyEntry) -> Int64 {
        switch entry {
        case .library(let clip): clip.id ?? 0
        case .clipboard: 0
        }
    }

    /// 主入口：时间→横向（capped gaps），碰撞避让分行，垂直居中，生成刻度。
    /// 可读优先：字号永不压缩；行数超出可用高度时拉宽时间轴（迭代），
    /// 让内容溢出屏幕意宽度由滑动浏览；仅在词条稀少时恰好铺满。
    static func layout(
        clips: [Clip],
        canvasSize: CGSize,
        fontBase: CGFloat,
        scale: CGFloat,
        offset: CGFloat
    ) -> Result {
        let entries = clips
            .sorted { $0.lastSeenAt < $1.lastSeenAt }
            .map(GalaxyEntry.library)
        guard !entries.isEmpty, canvasSize.width > 60, canvasSize.height > 80 else {
            return Result(
                words: [], ticks: [], minorTicks: [], contentWidth: 0, minEdge: 0, maxEdge: 0
            )
        }

        let sideMargin: CGFloat = 24
        let availableWidth = canvasSize.width - sideMargin * 2
        let scaleAreaHeight: CGFloat = 48
        let usableHeight = max(60, canvasSize.height - scaleAreaHeight)

        // 字号固定：频次越大越大（+2.5pt/次，视觉封顶 +12），不收缩
        let sizes: [CGFloat] = entries.map { entry in
            let extra = CGFloat(min(max(entry.saveCount - 1, 0), 4))
            return fontBase + extra * 2.5
        }
        let rowHeight = (sizes.max() ?? fontBase) + 14
        let maxRows = max(1, Int(usableHeight / rowHeight))

        // 迭代求最小内容宽：行数 ≤ maxRows；从铺满宽度开始逐步拉宽
        var contentWidth = availableWidth
        var placed = placeWords(
            entries: entries, sizes: sizes, axisWidth: contentWidth * scale
        )
        for _ in 0..<12 {
            let usedRows = placed.map(\.row).max().map { $0 + 1 } ?? 1
            if usedRows <= maxRows { break }
            let widen = max(1.15, CGFloat(usedRows) / CGFloat(maxRows))
            contentWidth = min(contentWidth * widen, availableWidth * 8)
            placed = placeWords(
                entries: entries, sizes: sizes, axisWidth: contentWidth * scale
            )
        }

        // 垂直：居中；溢出时底边贴着刻度区上沿（不遮刻度）
        let usedRows = placed.map(\.row).max().map { $0 + 1 } ?? 1
        let contentHeight = CGFloat(usedRows) * rowHeight
        let contentTop: CGFloat
        if contentHeight <= usableHeight {
            contentTop = (canvasSize.height - scaleAreaHeight - contentHeight) / 2
        } else {
            contentTop = canvasSize.height - scaleAreaHeight - contentHeight
        }
        let firstRowCenter = contentTop + rowHeight / 2
        let words = placed.map { word in
            Word(
                clipId: word.clipId, entry: word.entry, text: word.text,
                width: word.width, fontSize: word.fontSize, row: word.row,
                centerX: word.centerX + sideMargin + availableWidth / 2 + offset,
                centerY: firstRowCenter + CGFloat(word.row) * rowHeight
            )
        }
        let ticks = makeTicks(entries: entries, words: words, canvasSize: canvasSize)
        let minEdge = placed.map { $0.centerX - $0.chipWidth / 2 }.min() ?? 0
        let maxEdge = placed.map { $0.centerX + $0.chipWidth / 2 }.max() ?? 0
        return Result(
            words: words, ticks: ticks.0, minorTicks: ticks.1,
            contentWidth: contentWidth, minEdge: minEdge, maxEdge: maxEdge
        )
    }

    /// 时间→内容坐标 x（0 为内容中心），碰撞避让分到不同行。
    /// axisWidth：时间轴像素总宽（已含缩放）。
    private static func placeWords(
        entries: [GalaxyEntry],
        sizes: [CGFloat],
        axisWidth: CGFloat
    ) -> [Word] {
        // capped 累计时间 → 相对像素（gapCap 记 1 单位）
        var positions: [CGFloat] = []
        var unitsTotal: CGFloat = 0
        var previous: TimeInterval = 0
        for (index, entry) in entries.enumerated() {
            let time = entry.date.timeIntervalSince1970
            if index == 0 {
                positions.append(0)
            } else {
                let delta = max(0, min(time - previous, gapCap))
                unitsTotal += CGFloat(delta / gapCap)
                positions.append(unitsTotal)
            }
            previous = time
        }
        let unitPixel = unitsTotal > 0 ? axisWidth / unitsTotal : 0

        var rowRightEdges: [CGFloat] = []
        var words: [Word] = []
        for (index, entry) in entries.enumerated() {
            let raw = GalaxyModel.displayText(entry.text)
            guard !raw.isEmpty, index < sizes.count else { continue }
            let size = sizes[index]
            let (text, width) = measuredText(raw, fontSize: size)
            let x = (positions[index] - unitsTotal / 2) * unitPixel
            let half = width / 2 + chipPadX
            var row = 0
            while row < rowRightEdges.count, rowRightEdges[row] + rowGap > x - half {
                row += 1
            }
            if row == rowRightEdges.count { rowRightEdges.append(-.greatestFiniteMagnitude) }
            rowRightEdges[row] = x + half
            words.append(
                Word(
                    clipId: clipID(of: entry), entry: entry, text: text,
                    width: width, fontSize: size, row: row,
                    centerX: x, centerY: 0
                )
            )
        }
        return words
    }

    /// 主刻度（带日期标签）与次级细分刻度（表盘短刻度）。
    private static func makeTicks(
        entries: [GalaxyEntry], words: [Word], canvasSize: CGSize
    ) -> ([Tick], [CGFloat]) {
        guard let first = entries.first?.date,
              let last = entries.last?.date,
              let firstWord = words.min(by: { $0.centerX < $1.centerX }),
              let lastWord = words.max(by: { $0.centerX < $1.centerX })
        else { return ([], []) }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return ([], []) }
        let pixelSpan = lastWord.centerX - firstWord.centerX
        guard pixelSpan > 1 else { return ([], []) }
        let secondsPerPixel = span / Double(pixelSpan)

        let calendar = Calendar.current
        let formatter = DateFormatter()
        var step = DateComponents()
        var minorStep = DateComponents()
        if span > 3600 * 86400 {
            step.year = 1; minorStep.month = 1
            formatter.setLocalizedDateFormatFromTemplate("y")
        } else if span > 90 * 86400 {
            step.quarter = 1; minorStep.month = 1
            formatter.setLocalizedDateFormatFromTemplate("yMMM")
        } else if span > 14 * 86400 {
            step.month = 1; minorStep.day = 1
            formatter.setLocalizedDateFormatFromTemplate("MMM")
        } else if span > 2 * 86400 {
            step.day = 1; minorStep.hour = 3
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            step.hour = 6; minorStep.minute = 30
            formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        }

        func xFor(_ date: Date) -> CGFloat {
            firstWord.centerX + CGFloat(date.timeIntervalSince(first) / secondsPerPixel)
        }

        var ticks: [Tick] = []
        var previousX: CGFloat = -.greatestFiniteMagnitude
        var date = first
        while date <= last {
            let x = xFor(date)
            if x >= 0, x <= canvasSize.width, x - previousX > 44 {
                ticks.append(Tick(x: x, label: formatter.string(from: date)))
                previousX = x
            }
            guard let next = calendar.date(byAdding: step, to: date), next > date else { break }
            date = next
        }

        // 次级细分：短刻度不带标签；跳过与主刻度重叠处，限制总数
        let majorX = Set(ticks.map { Int($0.x.rounded()) })
        var minorTicks: [CGFloat] = []
        var minorPreviousX: CGFloat = -.greatestFiniteMagnitude
        date = first
        while date <= last, minorTicks.count < 240 {
            let x = xFor(date)
            if x >= 0, x <= canvasSize.width,
               x - minorPreviousX > 7,
               !majorX.contains(Int(x.rounded())) {
                minorTicks.append(x)
                minorPreviousX = x
            }
            guard let next = calendar.date(byAdding: minorStep, to: date), next > date else { break }
            date = next
        }
        return (ticks, minorTicks)
    }

    /// 测量并截断：超过 maxTextWidth 逐字截断加省略号（与渲染同参数测量）
    private static func measuredText(
        _ text: String, fontSize: CGFloat
    ) -> (text: String, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        let full = (text as NSString).size(withAttributes: attributes).width
        if full <= maxTextWidth {
            return (text, full)
        }
        let ellipsis = ("…" as NSString).size(withAttributes: attributes).width
        var result = ""
        var width: CGFloat = 0
        for character in text {
            let piece = (String(character) as NSString).size(withAttributes: attributes).width
            if width + piece + ellipsis > maxTextWidth { break }
            result.append(character)
            width += piece
        }
        return (result + "…", width + ellipsis)
    }

    static func entry(at point: CGPoint, in result: Result) -> GalaxyEntry? {
        result.words.first { word in
            abs(point.x - word.centerX) <= word.chipWidth / 2
                && abs(point.y - word.centerY) <= word.chipHeight / 2
        }?.entry
    }
}

private extension GalaxyEntry {
    var saveCount: Int {
        switch self {
        case .library(let clip): clip.count
        case .clipboard: 1
        }
    }

    var date: Date {
        switch self {
        case .library(let clip): clip.lastSeenAt
        case .clipboard: .now
        }
    }
}
