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
                    if let entry = TimeWallLayout.entry(
                        at: value.location, in: layout(size: proxy.size)
                    ) {
                        onSelect(
                            GalaxyItem(
                                clipId: TimeWallLayout.clipID(of: entry),
                                text: GalaxyModel.displayText(entry.text),
                                fontSize: 25,
                                entry: entry,
                                position: .zero
                            )
                        )
                    } else {
                        // 点空白＝取消选中（ESC 同效）
                        model.selectedItem = nil
                    }
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
    /// 时间轴最小缩小倍数：布局加宽上限为 8 屏宽，0.125× 让整条时间线
    /// 一屏排布；缩小后重新碰撞分行——宁可行数变多也不横向重叠
    static let minScale: Double = 0.125

    /// 刻度粒度按**可见时间窗**（秒/像素 × 画布宽）自适应：
    /// 缩远见月/年，缩近见日/时；与缩放联动而非固定于数据总跨度
    enum TickGranularity {
        case year, quarter, month, day, hour

        static func pick(forVisibleSpan span: TimeInterval) -> TickGranularity {
            if span > 540 * 86400 { return .year }
            if span > 90 * 86400 { return .quarter }
            if span > 14 * 86400 { return .month }
            if span > 2 * 86400 { return .day }
            return .hour
        }

        var step: DateComponents {
            var c = DateComponents()
            switch self {
            case .year: c.year = 1
            // byAdding 不支持 .quarter（返回原日期，旧代码因此零刻度）；季度 = 3 个月
            case .quarter: c.month = 3
            case .month: c.month = 1
            case .day: c.day = 1
            case .hour: c.hour = 6
            }
            return c
        }

        var minorStep: DateComponents {
            var c = DateComponents()
            switch self {
            case .year: c.month = 1
            case .quarter: c.month = 1
            case .month: c.day = 1
            case .day: c.hour = 3
            case .hour: c.minute = 30
            }
            return c
        }

        var formatTemplate: String {
            switch self {
            case .year: "y"
            case .quarter: "yMMM"
            case .month: "MMM"
            case .day: "MMMd"
            case .hour: "MMMdHHmm"
            }
        }
    }
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

        // 稳定性统一设计：行分配永久固定为 1× 基准布局，任何缩放都不换行。
        // · 1× 基准：二分精确最小零推挤宽（连续，无离散台阶）+ 最小位移装填；
        // · 放大（≥1）：位置纯等比，零跳变、锚点精确；
        // · 缩小（<1）：位置等比后同行内连续推挤——推挤量随缩放连续变化，
        //   不换行、不丢词、不横叠；刻度仍按时间映射（密集簇内近似）。
        let dates = entries.map(\.date)
        let (positions, unitsTotal) = cappedUnits(dates: dates)

        func zeroPushWidth(at scale: CGFloat) -> CGFloat {
            var lo = availableWidth
            var hi = availableWidth * 8
            if !placeWords(
                entries: entries, sizes: sizes, positions: positions,
                unitsTotal: unitsTotal, axisWidth: hi * scale, maxRows: maxRows
            ).pushed {
                for _ in 0..<12 where hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if placeWords(
                        entries: entries, sizes: sizes, positions: positions,
                        unitsTotal: unitsTotal, axisWidth: mid * scale, maxRows: maxRows
                    ).pushed {
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
            }
            return hi
        }

        let contentWidth = zeroPushWidth(at: 1)
        let base = placeWords(
            entries: entries, sizes: sizes, positions: positions,
            unitsTotal: unitsTotal, axisWidth: contentWidth, maxRows: maxRows
        ).words

        func scaled(_ word: Word) -> Word {
            Word(
                clipId: word.clipId, entry: word.entry, text: word.text,
                width: word.width, fontSize: word.fontSize, row: word.row,
                centerX: word.centerX * scale, centerY: word.centerY
            )
        }
        let placed: [Word]
        if scale >= 1 {
            placed = base.map(scaled)
        } else {
            // 同行连续推挤：等比缩小后，行内相邻胶囊不够 gap 时逐个右推
            let laneCount = max(1, maxRows)
            var lanes = [[Word]](repeating: [], count: laneCount)
            for word in base.map(scaled) {
                lanes[min(word.row, laneCount - 1)].append(word)
            }
            placed = lanes.enumerated().flatMap { lane, words in
                let sorted = words.sorted { $0.centerX < $1.centerX }
                var previousRight = -CGFloat.greatestFiniteMagnitude
                return sorted.map { word in
                    let x = max(word.centerX, previousRight + rowGap + word.chipWidth / 2)
                    previousRight = x + word.chipWidth / 2
                    return Word(
                        clipId: word.clipId, entry: word.entry, text: word.text,
                        width: word.width, fontSize: word.fontSize, row: lane,
                        centerX: x, centerY: word.centerY
                    )
                }
            }
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
        let ticks = makeTicks(
            dates: dates,
            positions: positions,
            unitsTotal: unitsTotal,
            unitPixel: unitsTotal > 0 ? contentWidth * scale / unitsTotal : 0,
            contentOrigin: sideMargin + availableWidth / 2 + offset,
            firstDate: dates.first,
            lastDate: dates.last,
            canvasSize: canvasSize
        )
        let minEdge = placed.map { $0.centerX - $0.chipWidth / 2 }.min() ?? 0
        let maxEdge = placed.map { $0.centerX + $0.chipWidth / 2 }.max() ?? 0
        return Result(
            words: words, ticks: ticks.0, minorTicks: ticks.1,
            contentWidth: contentWidth, minEdge: minEdge, maxEdge: maxEdge
        )
    }

    /// gap 封顶的时间→单位映射（0…total）：布局与刻度共用，
    /// 保证刻度与词条在同一映射下排布（长空档同等压缩）
    static func cappedUnits(dates: [Date]) -> (positions: [CGFloat], total: CGFloat) {
        var positions: [CGFloat] = []
        var total: CGFloat = 0
        var previous: TimeInterval = 0
        for (index, date) in dates.enumerated() {
            let time = date.timeIntervalSince1970
            if index == 0 {
                positions.append(0)
            } else {
                let delta = max(0, min(time - previous, gapCap))
                total += CGFloat(delta / gapCap)
                positions.append(total)
            }
            previous = time
        }
        return (positions, total)
    }

    /// 任意时刻→单位：落在两个词条间时按该区间同样的 gap 封顶插值
    static func unit(at date: Date, dates: [Date], positions: [CGFloat]) -> CGFloat {
        guard let first = dates.first, date > first, dates.count > 1 else { return 0 }
        if let last = dates.last, date >= last { return positions.last ?? 0 }
        var low = 0
        var high = dates.count - 1
        while low < high - 1 {
            let mid = (low + high) / 2
            if dates[mid] <= date { low = mid } else { high = mid }
        }
        let delta = date.timeIntervalSince1970 - dates[low].timeIntervalSince1970
        let capped = min(max(delta, 0), gapCap)
        return positions[low] + CGFloat(capped / gapCap)
    }

    /// 最小位移装填：词条按真实时间放到能零位移容纳的行（选右边缘最大的
    /// 紧凑行）；无零位移行时选右边缘最小的行，右推刚好够的距离。
    /// 行数 ≤ maxRows、同行永不重叠、位移只在必要时发生且取最小值。
    private static func placeWords(
        entries: [GalaxyEntry],
        sizes: [CGFloat],
        positions: [CGFloat],
        unitsTotal: CGFloat,
        axisWidth: CGFloat,
        maxRows: Int
    ) -> (words: [Word], pushed: Bool) {
        let unitPixel = unitsTotal > 0 ? axisWidth / unitsTotal : 0
        let laneCount = max(1, maxRows)
        var laneRight = [CGFloat](repeating: -.greatestFiniteMagnitude, count: laneCount)
        var words: [Word] = []
        var pushed = false
        for (index, entry) in entries.enumerated() {
            let raw = GalaxyModel.displayText(entry.text)
            guard !raw.isEmpty, index < sizes.count else { continue }
            let size = sizes[index]
            let (text, width) = measuredText(raw, fontSize: size)
            let timeX = (positions[index] - unitsTotal / 2) * unitPixel
            let half = width / 2 + chipPadX
            var lane = -1
            var tightest = -CGFloat.greatestFiniteMagnitude
            for candidate in 0..<laneCount
            where laneRight[candidate] + rowGap <= timeX - half {
                if lane < 0 || laneRight[candidate] > tightest {
                    tightest = laneRight[candidate]
                    lane = candidate
                }
            }
            var finalX = timeX
            if lane < 0 {
                pushed = true
                lane = 0
                for candidate in 1..<laneCount where laneRight[candidate] < laneRight[lane] {
                    lane = candidate
                }
                finalX = max(timeX, laneRight[lane] + rowGap + half)
            }
            laneRight[lane] = finalX + half
            words.append(
                Word(
                    clipId: clipID(of: entry), entry: entry, text: text,
                    width: width, fontSize: size, row: lane,
                    centerX: finalX, centerY: 0
                )
            )
        }
        return (words, pushed)
    }

    /// 主刻度（带日期标签）与次级细分刻度（表盘短刻度）。
    /// 刻度与词条共用同一 gap 封顶映射，任何缩放下都不会错位；
    /// 粒度按可见时间窗自适应（缩远见月/年，缩近见日/时）
    static func makeTicks(
        dates: [Date],
        positions: [CGFloat],
        unitsTotal: CGFloat,
        unitPixel: CGFloat,
        contentOrigin: CGFloat,
        firstDate: Date?,
        lastDate: Date?,
        canvasSize: CGSize
    ) -> ([Tick], [CGFloat]) {
        guard let first = firstDate, let last = lastDate else { return ([], []) }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return ([], []) }
        let pixelSpan = Double(unitsTotal * unitPixel)
        guard pixelSpan > 1 else { return ([], []) }
        let secondsPerPixel = span / pixelSpan
        let visibleSpan = Double(canvasSize.width) * secondsPerPixel
        let granularity = TickGranularity.pick(forVisibleSpan: visibleSpan)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        let step = granularity.step
        let minorStep = granularity.minorStep
        formatter.setLocalizedDateFormatFromTemplate(granularity.formatTemplate)

        func xFor(_ date: Date) -> CGFloat {
            (unit(at: date, dates: dates, positions: positions) - unitsTotal / 2)
                * unitPixel + contentOrigin
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
