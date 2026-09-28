// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
// or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
// License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import KeyboardShortcuts
import SwiftUI
import simd

enum GalaxyDistribution: String, CaseIterable {
    case fibonacci
    case latitude
}

/// 星图实时调参（滑块面板驱动，UserDefaults 持久化）
final class GalaxyTuning: ObservableObject {
    static let shared = GalaxyTuning()

    @Published var dispersion: Double { didSet { save("dispersion", dispersion) } }
    @Published var chromaExponent: Double { didSet { save("chromaExponent", chromaExponent) } }
    @Published var refraction: Double { didSet { save("refraction", refraction) } }
    @Published var warpFalloff: Double { didSet { save("warpFalloff", warpFalloff) } }
    @Published var rimStrength: Double { didSet { save("rimStrength", rimStrength) } }
    @Published var fresnelTint: Double { didSet { save("fresnelTint", fresnelTint) } }
    @Published var highlightIntensity: Double { didSet { save("highlightIntensity", highlightIntensity) } }
    @Published var causticIntensity: Double { didSet { save("causticIntensity", causticIntensity) } }
    @Published var innerRimStart: Double { didSet { save("innerRimStart", innerRimStart) } }
    @Published var rotationSpeed: Double { didSet { save("rotationSpeed", rotationSpeed) } }
    @Published var sphereScale: Double { didSet { save("sphereScale", sphereScale) } }
    @Published var ringScale: Double { didSet { save("ringScale", ringScale) } }
    @Published var coreDarkCenter: Double { didSet { save("coreDarkCenter", coreDarkCenter) } }
    @Published var coreDarkEdge: Double { didSet { save("coreDarkEdge", coreDarkEdge) } }
    @Published var reverseRotation: Bool {
        didSet { UserDefaults.standard.set(reverseRotation, forKey: "gt.reverseRotation") }
    }
    @Published var distribution: GalaxyDistribution {
        didSet { UserDefaults.standard.set(distribution.rawValue, forKey: "gt.distribution") }
    }

    init() {
        let defaults = UserDefaults.standard
        dispersion = defaults.object(forKey: "gt.dispersion") as? Double ?? 20
        chromaExponent = defaults.object(forKey: "gt.chromaExponent") as? Double ?? 2.0
        refraction = defaults.object(forKey: "gt.refraction") as? Double ?? 0.85
        warpFalloff = defaults.object(forKey: "gt.warpFalloff") as? Double ?? 1.0
        rimStrength = defaults.object(forKey: "gt.rimStrength") as? Double ?? 0.30
        fresnelTint = defaults.object(forKey: "gt.fresnelTint") as? Double ?? 0.16
        highlightIntensity = defaults.object(forKey: "gt.highlightIntensity") as? Double ?? 1.0
        causticIntensity = defaults.object(forKey: "gt.causticIntensity") as? Double ?? 1.0
        innerRimStart = defaults.object(forKey: "gt.innerRimStart") as? Double ?? 0.90
        rotationSpeed = defaults.object(forKey: "gt.rotationSpeed") as? Double ?? 0.06
        sphereScale = defaults.object(forKey: "gt.sphereScale") as? Double ?? 0.40
        ringScale = defaults.object(forKey: "gt.ringScale") as? Double ?? 1.25
        coreDarkCenter = defaults.object(forKey: "gt.coreDarkCenter") as? Double ?? 0.10
        coreDarkEdge = defaults.object(forKey: "gt.coreDarkEdge") as? Double ?? 0.28
        reverseRotation = defaults.bool(forKey: "gt.reverseRotation")
        distribution = GalaxyDistribution(rawValue: defaults.string(forKey: "gt.distribution") ?? "")
            ?? .fibonacci
    }

    private func save(_ name: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: "gt.\(name)")
    }

    func reset() {
        dispersion = 20; chromaExponent = 2.0; refraction = 0.85; warpFalloff = 1.0
        rimStrength = 0.30; fresnelTint = 0.16
        highlightIntensity = 1.0; causticIntensity = 1.0; innerRimStart = 0.90
        rotationSpeed = 0.06
        sphereScale = 0.40; ringScale = 1.25
        coreDarkCenter = 0.10; coreDarkEdge = 0.28
        reverseRotation = false
        distribution = .fibonacci
    }
}

// MARK: - 球面数据

enum GalaxySource: String, CaseIterable {
    /// 空间顺序即切换顺序:检索(左)↔词库(中)↔剪贴板(右)
    case search
    case library
    case clipboard
}

enum GalaxyEntry: Equatable {
    case library(Clip)
    case clipboard(ClipboardEntry)

    var text: String {
        switch self {
        case .library(let clip): clip.text
        case .clipboard(let entry): entry.text ?? ""
        }
    }

    var appName: String? {
        switch self {
        case .library(let clip): clip.appName
        case .clipboard(let entry): entry.appName
        }
    }

    var bundleID: String? {
        switch self {
        case .library(let clip): clip.appBundleID
        case .clipboard(let entry): entry.appBundleID
        }
    }

    var url: String? {
        switch self {
        case .library(let clip): clip.url
        case .clipboard(let entry): entry.url
        }
    }
}

struct GalaxyItem: Equatable {
    static let maximumTextAngle: Float = 1.18
    static let fontAngleScale: CGFloat = 0.00325

    let clipId: Int64
    let text: String
    let fontSize: CGFloat
    let entry: GalaxyEntry
    let position: SIMD3<Float>

    var angularHeight: Float {
        Float(min(max(fontSize * Self.fontAngleScale, 0.018), 0.20))
    }

    var sphereText: String {
        // 球面文字一律单行:换行/连续空白折叠为一个空格再截断。
        // 多行文本(常见于剪贴板段落)若原样渲染,会被压进固定高度文字带,
        // 行与行叠在一起且字号骤缩
        let flattened = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let lineHeight = font.ascender - font.descender + font.leading
        let maximumWidth = CGFloat(Self.maximumTextAngle / angularHeight) * lineHeight
        // 与渲染保持一致的字距,截断测量才准确
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .kern: fontSize * 0.02,
        ]
        if (flattened as NSString).size(withAttributes: attributes).width <= maximumWidth {
            return flattened
        }

        let ellipsisWidth = ("…" as NSString).size(withAttributes: attributes).width
        var result = ""
        var width: CGFloat = 0
        for character in flattened {
            let value = String(character)
            let characterWidth = (value as NSString).size(withAttributes: attributes).width
            guard width + characterWidth + ellipsisWidth <= maximumWidth else { break }
            result.append(character)
            width += characterWidth
        }
        return result + "…"
    }

    var isTruncated: Bool { sphereText != text }
}

@MainActor
final class GalaxyModel: ObservableObject {
    static let maxItems = 400

    @Published private(set) var items: [GalaxyItem] = []
    @Published var selectedItem: GalaxyItem?
    /// 双击词条发出的编辑请求(GalaxyView 监听后弹出编辑面板;剪贴板条目无编辑界面,忽略)
    @Published var pendingEdit: GalaxyItem?
    @Published var source: GalaxySource = GalaxySource(
        rawValue: UserDefaults.standard.string(forKey: "galaxyLastSource") ?? ""
    ) ?? .library {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "galaxyLastSource") }
    }
    /// 源切换动效方向(true=向前/右滑语义);由快捷键或顶栏切换设置,渲染层消费后置 nil
    @Published var pendingSourceSwitch: Bool?
    @Published var isTimelineVisible = false
    @Published var timelinePage = 0
    var timelinePageCount = 1
    private var timelineScrollDelta: CGFloat = 0
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: "galaxyFontScale") }
    }

    init() {
        fontScale = UserDefaults.standard.object(forKey: "galaxyFontScale") as? Double
            ?? 1.0
    }

    /// 调参面板开关：菜单栏「星图」菜单持有，会话内共享
    @Published var showTuning = false

    /// 指针悬停在星图设置面板上：滚轮/捏合让位给面板自身（非发布，避免重绘）
    var isPointerOverGalaxySettings = false

    /// 检索档时间词墙：时间轴缩放（1 = 默认视野）与水平平移（像素）
    @Published var timeWallScale: Double = 1
    @Published var timeWallOffset: Double = 0
    /// 词墙内容实际边缘（含胶囊半宽，布局回写；平移边界用它计算）
    var timeWallEdges: (min: CGFloat, max: CGFloat)?

    func zoomTimeWall(by factor: Double, anchorX: Double?, canvasWidth: Double?) {
        let old = timeWallScale
        let new = min(max(old * factor, 1), TimeWallLayout.maxScale)
        guard new != old else { return }
        timeWallScale = new
        // 以指针为锚缩放：保持锚点下的时刻不动
        if let anchorX, let width = canvasWidth {
            let center = width / 2
            let ratio = new / old
            timeWallOffset = (anchorX - center) * (1 - ratio) + timeWallOffset * ratio
        }
        clampTimeWallOffset(canvasWidth: canvasWidth)
    }

    func panTimeWall(by delta: Double, canvasWidth: Double?) {
        timeWallOffset += delta
        clampTimeWallOffset(canvasWidth: canvasWidth)
    }

    func resetTimeWall() {
        timeWallScale = 1
        timeWallOffset = 0
    }

    /// 平移边界：以实际内容边缘为准（含胶囊半宽，两侧各留 24pt）。
    /// 正向平移看更旧（左端），负向看更新（右端）；内容不溢出时固定居中。
    private func clampTimeWallOffset(canvasWidth: Double?) {
        guard let width = canvasWidth, let edges = timeWallEdges else { return }
        if edges.max - edges.min <= width - 48 {
            timeWallOffset = 0
            return
        }
        let lower = Double(width / 2 - 24 - edges.max)
        let upper = Double(24 - width / 2 - edges.min)
        timeWallOffset = min(max(timeWallOffset, lower), upper)
    }

    func rebuild(from clips: [Clip], announceSampling: Bool = true) {
        let sampled: [Clip]
        if clips.count > Self.maxItems {
            sampled = Array(
                clips
                    .sorted { ($0.count, $0.lastSeenAt) > ($1.count, $1.lastSeenAt) }
                    .prefix(Self.maxItems)
            )
            if announceSampling {
                ToastController.shared.show(L10n.format("星图显示前 %d 条（按频次与最近度）", Self.maxItems))
            }
        } else {
            sampled = clips
        }

        makeItems(from: sampled.map(GalaxyEntry.library))
        selectedItem = nil
        isTimelineVisible = false
        timelinePage = 0
    }

    func rebuild(fromClipboard entries: [ClipboardEntry]) {
        let selectedID: UUID?
        if case .clipboard(let selected)? = selectedItem?.entry {
            selectedID = selected.id
        } else {
            selectedID = nil
        }
        let textEntries = entries.compactMap { entry in
            entry.text == nil ? nil : entry
        }
        let sampled: [ClipboardEntry]
        if textEntries.count > Self.maxItems {
            sampled = Array(textEntries.prefix(Self.maxItems))
            ToastController.shared.show(L10n.format("星图显示前 %d 条（按最近复制）", Self.maxItems))
        } else {
            sampled = textEntries
        }
        makeItems(from: sampled.map(GalaxyEntry.clipboard))
        selectedItem = items.first { item in
            if case .clipboard(let entry) = item.entry { return entry.id == selectedID }
            return false
        }
        isTimelineVisible = false
        timelinePage = 0
    }

    func relayout() {
        let selectedID = selectedItem?.clipId
        makeItems(from: items.map(\.entry))
        selectedItem = items.first { $0.clipId == selectedID }
    }

    private func makeItems(from entries: [GalaxyEntry]) {
        let positions = Self.positions(count: entries.count, distribution: GalaxyTuning.shared.distribution)
        items = entries.enumerated().map { index, entry in
            let id: Int64
            switch entry {
            case .library(let clip): id = clip.id ?? 0
            case .clipboard: id = -Int64(index + 1)
            }
            return GalaxyItem(
                clipId: id,
                text: Self.displayText(entry.text),
                fontSize: 25,
                entry: entry,
                position: positions[index]
            )
        }
    }

    private static func positions(count: Int, distribution: GalaxyDistribution) -> [SIMD3<Float>] {
        guard count > 0 else { return [] }
        switch distribution {
        case .fibonacci:
            let goldenAngle = Float.pi * (3.0 - sqrt(5.0))
            return (0..<count).map { index in
                let y = 1.0 - 2.0 * (Float(index) + 0.5) / Float(count)
                let radius = sqrt(max(0, 1 - y * y))
                let theta = goldenAngle * Float(index)
                return SIMD3(radius * cos(theta), y, radius * sin(theta))
            }
        case .latitude:
            return latitudePositions(count: count)
        }
    }

    private static func latitudePositions(count: Int) -> [SIMD3<Float>] {
        let bands = min(count, max(1, Int((Double(count) * .pi).squareRoot().rounded())))
        let verticalExtent = 0.85
        let weights = (0..<bands).map { band in
            let latitude = Double.pi * (Double(band) + 0.5) / Double(bands)
            let y = verticalExtent * cos(latitude)
            return sqrt(max(0, 1 - y * y))
        }
        let totalWeight = weights.reduce(0, +)
        let target = weights.map { Double(count) * $0 / totalWeight }
        var slots = [Int](repeating: 1, count: bands)
        let middle = bands / 2
        if !bands.isMultiple(of: 2), count.isMultiple(of: 2) {
            slots[middle] = 2
        }
        var remaining = count - slots.reduce(0, +)
        while remaining >= 2 {
            var bestBand = 0
            var largestDeficit = -Double.infinity
            for band in 0..<((bands + 1) / 2) {
                let deficit = target[band] - Double(slots[band])
                if deficit > largestDeficit {
                    largestDeficit = deficit
                    bestBand = band
                }
            }
            if bestBand == middle {
                slots[middle] += 2
            } else {
                slots[bestBand] += 1
                slots[bands - bestBand - 1] += 1
            }
            remaining -= 2
        }
        if remaining == 1 { slots[middle - 1] += 1 }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        for band in 0..<bands {
            let latitude = Float.pi * (Float(band) + 0.5) / Float(bands)
            let y = Float(verticalExtent) * cos(latitude)
            let radius = sqrt(max(0, 1 - y * y))
            let phase: Float = band.isMultiple(of: 2) || slots[band] == 1 ? 0 : 0.5
            for slot in 0..<slots[band] {
                let theta = Float.pi / 2 + 2 * Float.pi * (Float(slot) + phase) / Float(slots[band])
                result.append(SIMD3(radius * cos(theta), y, radius * sin(theta)))
            }
        }
        return result
    }

    func turnTimelinePage(with event: NSEvent) {
        guard isTimelineVisible, timelinePageCount > 1,
              event.momentumPhase == [] else { return }
        if event.phase == .began {
            timelineScrollDelta = 0
        }
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let delta = event.scrollingDeltaY * direction
        guard delta != 0 else { return }
        if !event.hasPreciseScrollingDeltas {
            timelinePage = min(max(timelinePage + (delta < 0 ? 1 : -1), 0), timelinePageCount - 1)
            return
        }
        timelineScrollDelta += delta
        guard abs(timelineScrollDelta) >= 60 else { return }
        timelinePage = min(
            max(timelinePage + (timelineScrollDelta < 0 ? 1 : -1), 0),
            timelinePageCount - 1
        )
        timelineScrollDelta = 0
    }

    func zoom(by factor: Double) {
        fontScale = min(max(fontScale * factor, 0.5), 2.5)
    }

    static func displayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 全屏窗口控制器

private final class GalaxyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class GalaxyWindowController {
    static let shared = GalaxyWindowController()

    private var window: NSWindow?
    private var eventMonitor: Any?
    let model = GalaxyModel()

    var isOpen: Bool { window?.isVisible == true }
    var isActive: Bool { NSApp.isActive && window?.isKeyWindow == true }
    var hostedWindow: NSWindow? { window }
    var source: GalaxySource { model.source }

    func open(source: GalaxySource? = nil, initiallyTransparent: Bool = false) {
        if let source { model.source = source }
        switch model.source {
        case .library:
            model.rebuild(from: AppModel.shared.store.clips)
        case .clipboard:
            model.rebuild(fromClipboard: AppModel.shared.clipboardWatcher.entries)
        case .search:
            model.rebuild(from: AppModel.shared.store.clips, announceSampling: false)
        }
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let window: NSWindow
        if let existingWindow = self.window {
            window = existingWindow
            window.setFrame(screenFrame, display: true)
        } else {
            let contentView = GalaxyView(model: model)
                .environmentObject(AppModel.shared.store)
                .environmentObject(AppModel.shared.clipboardWatcher)
            window = GalaxyWindow(
                contentRect: screenFrame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: DisplayLanguageView(content: contentView))
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.identifier = NSUserInterfaceItemIdentifier("voca.galaxy")
            self.window = window
        }

        installEventMonitor()
        window.alphaValue = initiallyTransparent ? 0 : 1
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setGalaxyRendering(paused: false, in: window.contentView)
        WorkspaceNavigation.shared.noteGalaxyOpened()
    }

    func close() {
        removeEventMonitor()
        guard let window else { return }
        setGalaxyRendering(paused: true, in: window.contentView)
        model.selectedItem = nil
        window.orderOut(nil)
        window.alphaValue = 1
    }

    func switchSource(forward: Bool) {
        let order = GalaxySource.allCases
        guard let index = order.firstIndex(of: model.source) else { return }
        let next = index + (forward ? 1 : -1)
        guard order.indices.contains(next) else { return }
        model.pendingSourceSwitch = forward
        model.source = order[next]
    }

    static func keepTuningShortcutLocal() {
        _ = KeyboardShortcuts.Name.galaxyTuning
        KeyboardShortcuts.disable(.galaxyTuning)
    }

    nonisolated static func shouldToggleTuning(
        for event: NSEvent, galaxyIsFocused: Bool, shortcut: KeyboardShortcuts.Shortcut?
    ) -> Bool {
        guard galaxyIsFocused, event.type == .keyDown, !event.isARepeat,
              let shortcut, let pressed = KeyboardShortcuts.Shortcut(event: event)
        else { return false }
        return pressed == shortcut
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .magnify]
        ) {
            [weak self] event in
            guard let self, self.isOpen else { return event }
            if Self.shouldToggleTuning(
                for: event, galaxyIsFocused: self.isActive,
                shortcut: KeyboardShortcuts.getShortcut(for: .galaxyTuning)
            ) {
                self.model.showTuning.toggle()
                return nil
            }
            if event.type == .scrollWheel, self.model.isTimelineVisible,
               event.window === self.window {
                self.model.turnTimelinePage(with: event)
                return nil
            }
            // 时间线档：双指左右滑动/拖动＝平移；垂直滚轮或双指上下滚＝缩放（与捏合并存）；
            // 指针悬停在星图设置面板上时让位，滚动/捏合交给面板自身
            if self.model.source == .search,
               event.type == .scrollWheel || event.type == .magnify,
               !self.model.isPointerOverGalaxySettings,
               self.window?.frame.contains(NSEvent.mouseLocation) == true {
                let width = self.window?.contentView?.bounds.width ?? 0
                switch event.type {
                case .scrollWheel:
                    if event.scrollingDeltaX != 0 {
                        // 自然滚动方向：内容跟随手指（含惯性阶段）
                        self.model.panTimeWall(
                            by: -Double(event.scrollingDeltaX), canvasWidth: width
                        )
                        return nil
                    }
                    guard event.momentumPhase == [], event.scrollingDeltaY != 0 else {
                        return event
                    }
                    let sensitivity = event.hasPreciseScrollingDeltas ? 0.006 : 0.075
                    self.model.zoomTimeWall(
                        by: exp(event.scrollingDeltaY * sensitivity),
                        anchorX: event.locationInWindow.x,
                        canvasWidth: width
                    )
                    return nil
                case .magnify:
                    let width = self.window?.contentView?.bounds.width ?? 0
                    self.model.zoomTimeWall(
                        by: max(0.1, 1 + event.magnification * 1.2),
                        anchorX: event.locationInWindow.x,
                        canvasWidth: width
                    )
                    return nil
                default:
                    break
                }
            }
            guard event.type == .keyDown, event.window === self.window,
                  event.keyCode == 53 else { return event }
            if self.model.selectedItem != nil {
                self.model.selectedItem = nil
            } else {
                DispatchQueue.main.async {
                    GalaxyWindowController.shared.close()
                }
            }
            return nil
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private func setGalaxyRendering(paused: Bool, in view: NSView?) {
        guard let view else { return }
        if let sceneView = view as? GalaxySceneView {
            paused ? sceneView.pauseRendering() : sceneView.resumeRendering()
        } else if let lensView = view as? GalaxyLensMetalView {
            paused ? lensView.pauseRendering() : lensView.resumeRendering()
        }
        for subview in view.subviews {
            setGalaxyRendering(paused: paused, in: subview)
        }
    }
}

// MARK: - 星图视图

private enum GalaxyOrbitSide {
    case left
    case right
}

private struct GalaxyView: View {
    @ObservedObject var model: GalaxyModel
    @ObservedObject private var tuning = GalaxyTuning.shared
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("galaxyChromeFontSize") private var galaxyChromeFontSize = 13.0
    @AppStorage("timelineBackgroundStrength") private var timelineBackgroundStrength = 70.0
    @State private var editingClip: Clip?
    @State private var deletingEntry: GalaxyEntry?
    @State private var promotedIDs: Set<UUID> = []
    @State private var timelineEvents: [ClipEvent] = []
    @State private var selectedTimelineIndex = 0

    var body: some View {
        GeometryReader { geometry in
            galaxyContent(geometry)
        }
        .background(.clear)
        .onChange(of: tuning.distribution) { _, _ in handleDistributionChange() }
        .onChange(of: model.source) { oldSource, newSource in
            handleSourceChange(from: oldSource, to: newSource)
        }
        .onChange(of: watcher.entries) { _, entries in handleClipboardEntries(entries) }
        .onChange(of: model.selectedItem?.clipId) { _, _ in handleSelectionChange() }
        .onChange(of: model.timelinePage) { _, _ in selectedTimelineIndex = 0 }
        .onChange(of: model.pendingEdit) { _, item in handlePendingEdit(item) }
        .sheet(item: $editingClip) { clip in
            editSheet(for: clip)
        }
        .confirmationDialog(
            deletingClipboard ? L10n.text("移除这条剪贴板记录？") : L10n.text("删除这个词条？"),
            isPresented: deletingEntryBinding,
            titleVisibility: .visible
        ) {
            deleteDialogActions
        } message: {
            deleteDialogMessage
        }
    }

    /// 星图主体(从 body 抽出,避免顶层表达式过长导致类型检查超时)
    private func galaxyContent(_ geometry: GeometryProxy) -> some View {
        let radius = min(geometry.size.width, geometry.size.height) * tuning.sphereScale

        return ZStack {
            if model.source == .search {
                timelineLayout(availableWidth: geometry.size.width)
            } else {
                sphere(diameter: radius * 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                VStack {
                    Spacer()
                    selectionDetail(availableWidth: geometry.size.width)
                }
                .padding(20)
            }

            if let item = model.selectedItem, model.source != .search {
                selectionOrbit(
                    item.entry,
                    sphereDiameter: radius * 2,
                    canvasSize: geometry.size
                )
                .transition(selectionTransition)
            }

            // 调参面板必须在选中轨道/时间线之上：否则全屏 Canvas 会拦截滑杆的点击
            tuningOverlay
        }
        .animation(selectionAnimation, value: model.selectedItem?.clipId)
        .animation(selectionAnimation, value: model.isTimelineVisible)
        .animation(selectionAnimation, value: model.timelinePage)
    }

    private var deletingClipboard: Bool {
        guard let deletingEntry else { return false }
        if case .clipboard = deletingEntry { return true }
        return false
    }

    /// 时间线档：全屏时间词墙（磨砂背景全幅）；调参面板为左上真浮窗；
    /// 选中详情作为浮层盖在刻度之上（不挤压词墙布局）。
    private func timelineLayout(availableWidth: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { area in
                searchDanmakuLayer(area)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AnyShapeStyle(.regularMaterial)
                    .opacity(Double(timelineBackgroundStrength) / 100)
            )

            tuningOverlay

            if model.selectedItem != nil {
                selectionDetail(availableWidth: availableWidth)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
    }

    /// 仅将当前检索结果交给时间词墙；空查询仍展示整个词库。
    @ViewBuilder
    private func searchDanmakuLayer(_ geometry: GeometryProxy) -> some View {
        if store.clips.isEmpty {
            ContentUnavailableView(
                "词库还是空的",
                systemImage: "list.bullet.rectangle",
                description: Text("保存一些文字后，它们会出现在这里。")
            )
            .frame(maxWidth: 480)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        } else {
            GalaxyTimeWallView(
                model: model,
                clips: store.clips,
                chromeBase: galaxyChromeFontSize,
                onSelect: { item in
                    withAnimation(selectionAnimation) {
                        model.selectedItem = item
                    }
                },
                onLookup: { entry in
                    LookupPopupController.shared.handleViewOnly(entry.text)
                }
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func handleDistributionChange() {
        model.relayout()
    }

    private func handleSourceChange(from oldSource: GalaxySource, to source: GalaxySource) {
        model.selectedItem = nil
        // 顶栏切换无方向语义,按两个源的固定位置推导;快捷键路径已携带方向,不覆盖
        if model.pendingSourceSwitch == nil {
            let order = GalaxySource.allCases
            model.pendingSourceSwitch =
                order.firstIndex(of: source)! > order.firstIndex(of: oldSource)!
        }
        // 无障碍:减弱动态效果时不播旋转动效,直接重建
        if reduceMotion {
            model.pendingSourceSwitch = nil
        }
        switch source {
        case .search:
            model.rebuild(from: AppModel.shared.store.clips, announceSampling: false)
        case .library:
            model.rebuild(from: store.clips)
        case .clipboard:
            model.rebuild(fromClipboard: watcher.entries)
        }
    }

    private func handleClipboardEntries(_ entries: [ClipboardEntry]) {
        if model.source == .clipboard {
            model.rebuild(fromClipboard: entries)
        }
    }

    private func handleSelectionChange() {
        if let item = model.selectedItem, case .library(let clip) = item.entry {
            timelineEvents = store.events(for: clip)
        } else {
            timelineEvents = []
        }
        model.timelinePageCount = max(1, (timelineEvents.count + 5) / 6)
        model.isTimelineVisible = false
        model.timelinePage = 0
        selectedTimelineIndex = 0
        model.showTuning = false
    }

    private func editSheet(for clip: Clip) -> some View {
        EditClipSheet(clip: clip) { text, note in
            store.update(clip, text: text, note: note)
            model.rebuild(from: store.clips)
            if let id = clip.id {
                model.selectedItem = model.items.first { $0.clipId == id }
            }
        }
    }

    private var deletingEntryBinding: Binding<Bool> {
        Binding(
            get: { deletingEntry != nil },
            set: { if !$0 { deletingEntry = nil } }
        )
    }

    @ViewBuilder
    private var deleteDialogActions: some View {
        Button(
            deletingClipboard ? L10n.text("移除剪贴板记录") : L10n.text("删除词条（不可恢复）"),
            role: .destructive
        ) {
            deleteSelectedEntry()
        }
        Button("取消", role: .cancel) {
            deletingEntry = nil
        }
    }

    private var deleteDialogMessage: Text {
        Text(
            deletingClipboard
                ? L10n.text("仅从剪贴板历史移除，不影响已入库的词条。")
                : L10n.text("将永久删除该词条及其全部时间线事件，不影响剪贴板历史。"))
    }

    /// 双击词条 → 弹出编辑面板(剪贴板条目无编辑界面,忽略)
    private func handlePendingEdit(_ item: GalaxyItem?) {
        model.pendingEdit = nil
        guard let item, case .library(let clip) = item.entry else { return }
        editingClip = clip
    }

    private func deleteSelectedEntry() {
        guard let entry = deletingEntry else { return }
        deletingEntry = nil
        switch entry {
        case .library(let clip):
            store.delete(clip)
            model.rebuild(from: store.clips)
        case .clipboard(let clipboard):
            watcher.remove(clipboard)
            model.rebuild(fromClipboard: watcher.entries)
        }
    }

    private func sphere(diameter: CGFloat) -> some View {
        // 三种源共用同一套球体视觉(磨砂核 + 折射透镜环);检索模式仅在内容上不同
        let lensDiameter = diameter * tuning.ringScale
        let radius = diameter / 2
        return ZStack {
            // 折射透镜（捕获可用时呈现折射 + 色散）
            GalaxyLensView()
                .clipShape(Circle())
                .frame(width: lensDiameter, height: lensDiameter)
                .allowsHitTesting(false)

            // 玻璃兜底（捕获不可用时仍有玻璃感）
            Circle()
                .fill(.clear)
                .glassEffect(.clear, in: Circle())
                .frame(width: lensDiameter, height: lensDiameter)

            // 内核磨砂材质 + 暗色偏置
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .black.opacity(tuning.coreDarkCenter),
                            .black.opacity(tuning.coreDarkEdge),
                        ],
                        center: UnitPoint(x: 0.5, y: 0.45),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
                .frame(width: diameter, height: diameter)
            // 左上高光 + 边缘光：玻璃质感（两种模式共用）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.22), .clear],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)

            Group {
                if model.items.isEmpty {
                    ContentUnavailableView(
                        model.source == .library
                            ? L10n.text("星图还是空的")
                            : model.source == .clipboard
                                ? L10n.text("暂无剪贴板文字")
                                : L10n.text("词库还是空的"),
                        systemImage: "sparkles",
                        description: Text(
                            model.source == .library
                                ? L10n.text("保存一些文字后，它们会出现在这里。")
                                : model.source == .clipboard
                                    ? L10n.text("复制文字后，它会出现在这里；图片和文件仍可在剪贴板历史中查看。")
                                    : L10n.text("保存一些文字后，它们会出现在这里。")
                        )
                    )
                    .frame(maxWidth: diameter * 0.56)
                } else {
                    GalaxySphereView(model: model, reverseRotation: tuning.reverseRotation)
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: lensDiameter, height: lensDiameter)
    }

    // MARK: 顶部与提示

    /// 星图界面文字：设置页「星图界面字号」驱动，各元素按相对偏移派生
    /// （轨道卡值 +0，轨道卡标题 +2，注释卡 +1，页码 -1）
    private func chromeSize(_ offset: Double = 0) -> CGFloat {
        Typography.derived(galaxyChromeFontSize, offset: offset)
    }

    @ViewBuilder
    private func selectionDetail(availableWidth: CGFloat) -> some View {
        if let item = model.selectedItem {
            switch item.entry {
            case .library(let clip):
                if !model.isTimelineVisible {
                    let note = clip.note.flatMap { value -> String? in
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                    }
                    if item.isTruncated {
                        let detail = note.map { clip.text + "\n\n" + $0 } ?? clip.text
                        noteBelowSphere(
                            detail,
                            availableWidth: availableWidth,
                            label: note == nil ? L10n.text("原文") : L10n.text("原文与备注")
                        )
                    } else if let note {
                        noteBelowSphere(note, availableWidth: availableWidth)
                    }
                }
            case .clipboard(let entry):
                if let text = entry.text {
                    noteBelowSphere(text, availableWidth: availableWidth, label: "剪贴板全文")
                }
            }
            selectionActions(item.entry)
        }
    }

    private func noteBelowSphere(
        _ note: String,
        availableWidth: CGFloat,
        label: String = "注释"
    ) -> some View {
        let width = min(560, max(220, availableWidth - 48))
        let fontSize = chromeSize(1)
        let textHeight = (note as NSString).boundingRect(
            with: CGSize(width: width - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        ).height

        return ScrollView(.vertical) {
            Text(note)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .frame(width: width, height: min(160, max(44, ceil(textHeight) + 28)))
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        )
        .padding(.bottom, 12)
        .accessibilityLabel(label)
    }

    // MARK: 星图设置面板

    /// 调参浮窗：左上悬浮玻璃卡（球体档与时间线档共用同一呈现）
    @ViewBuilder
    private var tuningOverlay: some View {
        if model.showTuning {
            tuningPanel
                .padding(.leading, 24)
                .padding(.top, 24)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
    }

    private var tuningPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("星图设置", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Button("重置") {
                        tuning.reset()
                        model.fontScale = 1.0
                        galaxyChromeFontSize = 13
                        timelineBackgroundStrength = 70
                    }
                    .buttonStyle(.glass)
                    Button {
                        model.showTuning = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.glass)
                    .help("收起")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("文字排布").font(.caption)
                    Picker("文字排布", selection: $tuning.distribution) {
                        Text("均匀散点").tag(GalaxyDistribution.fibonacci)
                        Text("纬线").tag(GalaxyDistribution.latitude)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Picker("旋转方向", selection: $tuning.reverseRotation) {
                    Text("正向").tag(false)
                    Text("反向").tag(true)
                }
                .pickerStyle(.segmented)
                Text("正向：文字跟随指针或手指移动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tuningSlider("自转速度", value: $tuning.rotationSpeed, range: 0...0.15, format: "%.3f")
                Text("0 表示静止不动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                tuningSlider("色散强度", value: $tuning.dispersion, range: 0...30, format: "%.1f")
                tuningSlider("色散分布", value: $tuning.chromaExponent, range: 1...4, format: "%.2f")
                tuningSlider("折射扭曲", value: $tuning.refraction, range: 0...1, format: "%.2f")
                tuningSlider("扭曲衰减", value: $tuning.warpFalloff, range: 0.4...2, format: "%.2f")
                tuningSlider("边缘厚度", value: $tuning.rimStrength, range: 0...0.6, format: "%.2f")
                tuningSlider("内圈起始", value: $tuning.innerRimStart, range: 0.8...0.95, format: "%.2f")
                tuningSlider("菲涅尔蓝", value: $tuning.fresnelTint, range: 0...0.4, format: "%.2f")
                tuningSlider("高光强度", value: $tuning.highlightIntensity, range: 0...2, format: "%.2f")
                tuningSlider("光斑强度", value: $tuning.causticIntensity, range: 0...3, format: "%.2f")

                Divider()

                tuningSlider("文字大小", value: $model.fontScale, range: 0.5...2.5, format: "%.2f×")
                Text("作用于球面文字与时间线词条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tuningSlider("星图界面字号", value: $galaxyChromeFontSize, range: 12...18, format: "%.0f pt")
                Text("应用于星图轨道卡、注释卡与时间线词条；球面文字用「文字大小」调整")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tuningSlider("时间线背景", value: $timelineBackgroundStrength, range: 30...100, format: "%.0f%%")
                Text("时间线磨砂浓度：越低越透出桌面，越高越护眼")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                tuningSlider("球体大小", value: $tuning.sphereScale, range: 0.25...0.48, format: "%.2f")
                tuningSlider("环宽倍数", value: $tuning.ringScale, range: 1.05...1.6, format: "%.2f")
                tuningSlider("磨砂中心暗度", value: $tuning.coreDarkCenter, range: 0...0.4, format: "%.2f")
                tuningSlider("磨砂边缘暗度", value: $tuning.coreDarkEdge, range: 0...0.6, format: "%.2f")
            }
            .padding(18)
        }
        .frame(width: 250)
        .frame(maxHeight: 430)
        .onHover { hovering in
            model.isPointerOverGalaxySettings = hovering
        }
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        )
    }

    private func tuningSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text(title)).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: 选择轨道

    private static let timelinePageSize = 6
    private static let orbitLabelGap: CGFloat = 43

    private var selectionAnimation: Animation {
        reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.30)
    }

    private var selectionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.985))
    }

    private var visibleTimelineEvents: [ClipEvent] {
        let start = model.timelinePage * Self.timelinePageSize
        guard start < timelineEvents.count else { return [] }
        return Array(timelineEvents.dropFirst(start).prefix(Self.timelinePageSize))
    }

    private var selectedTimelineEvent: ClipEvent? {
        let events = visibleTimelineEvents
        guard events.indices.contains(selectedTimelineIndex) else { return nil }
        return events[selectedTimelineIndex]
    }

    private func selectionOrbit(
        _ entry: GalaxyEntry,
        sphereDiameter: CGFloat,
        canvasSize: CGSize
    ) -> some View {
        let sphereRadius = sphereDiameter / 2
        let lensRadius = sphereRadius * tuning.ringScale
        let preferredRadius = (sphereRadius + lensRadius) / 2
        let verticalLimit = max(120, canvasSize.height / 2 - 72)
        let orbitRadius = min(preferredRadius, verticalLimit)
        let sideRoom = (canvasSize.width - orbitRadius * 2) / 2 - Self.orbitLabelGap - 8
        let sideWidth = min(208, max(120, sideRoom))
        let verticalOffset = min(190, orbitRadius * 0.48)

        return ZStack {
            if model.isTimelineVisible, case .library = entry {
                timelineOrbit(
                    canvasSize: canvasSize,
                    radius: orbitRadius,
                    sideWidth: sideWidth
                )
                .id(model.timelinePage)
                .transition(.opacity)
            } else {
                attributeOrbit(
                    entry,
                    canvasSize: canvasSize,
                    radius: orbitRadius,
                    sideWidth: sideWidth,
                    verticalOffset: verticalOffset
                )
                .transition(.opacity)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.source == .clipboard ? L10n.text("剪贴板属性")
                : model.isTimelineVisible ? L10n.text("词条时间线") : L10n.text("词条属性")
        )
    }

    private func attributeOrbit(
        _ entry: GalaxyEntry,
        canvasSize: CGSize,
        radius: CGFloat,
        sideWidth: CGFloat,
        verticalOffset: CGFloat
    ) -> some View {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let leftX = center.x - radius - Self.orbitLabelGap - sideWidth / 2
        let rightX = center.x + radius + Self.orbitLabelGap + sideWidth / 2
        let sourceURL = entry.url.flatMap(URL.init(string:))
        let sourceName = sourceURL?.host ?? L10n.text("无网页来源")

        return ZStack {
            orbitConnectorGuide(
                canvasSize: canvasSize,
                radius: radius,
                verticalOffsets: [-verticalOffset, verticalOffset]
            )

            orbitAttribute(
                title: "来源应用",
                value: entry.appName ?? L10n.text("未知来源"),
                systemImage: "app.dashed",
                appBundleID: entry.bundleID,
                side: .left
            )
            .frame(width: sideWidth)
            .position(x: leftX, y: center.y - verticalOffset)

            if let sourceURL {
                orbitAttribute(
                    title: "来源网页",
                    value: sourceName,
                    systemImage: "link",
                    side: .left,
                    action: { NSWorkspace.shared.open(sourceURL) }
                )
                .frame(width: sideWidth)
                .position(x: leftX, y: center.y + verticalOffset)
            } else {
                orbitAttribute(
                    title: "来源网页",
                    value: sourceName,
                    systemImage: "link",
                    side: .left
                )
                .frame(width: sideWidth)
                .position(x: leftX, y: center.y + verticalOffset)
            }

            switch entry {
            case .library(let clip):
                orbitAttribute(
                    title: "保存次数",
                    value: L10n.format("%d 次记录", clip.count),
                    systemImage: "square.stack.3d.up",
                    side: .right
                )
                .frame(width: sideWidth)
                .position(x: rightX, y: center.y - verticalOffset)

                orbitAttribute(
                    title: "时间线",
                    value: timelineEvents.isEmpty ? L10n.text("无记录") : L10n.format("%d 次记录", timelineEvents.count),
                    systemImage: "clock.arrow.circlepath",
                    side: .right,
                    action: timelineEvents.isEmpty ? nil : {
                        withAnimation(selectionAnimation) {
                            selectedTimelineIndex = 0
                            model.isTimelineVisible = true
                        }
                    }
                )
                .frame(width: sideWidth)
                .position(x: rightX, y: center.y + verticalOffset)
            case .clipboard(let clipboard):
                orbitAttribute(
                    title: "复制时间",
                    value: clipboard.date.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock",
                    side: .right,
                    lineLimit: 2
                )
                .frame(width: sideWidth)
                .position(x: rightX, y: center.y - verticalOffset)

                orbitAttribute(
                    title: "文本长度",
                    value: L10n.format("%d 字符", clipboard.text?.count ?? 0),
                    systemImage: "textformat",
                    side: .right
                )
                .frame(width: sideWidth)
                .position(x: rightX, y: center.y + verticalOffset)
            }
        }
    }

    private func timelineOrbit(
        canvasSize: CGSize,
        radius: CGFloat,
        sideWidth: CGFloat
    ) -> some View {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let events = visibleTimelineEvents
        let rows = (events.count + 1) / 2
        let spacing = min(172, radius * 0.48)
        let arcHalfHeight = CGFloat(max(0, rows - 1)) * spacing / 2

        return ZStack {
            Canvas { context, _ in
                for direction in [-1.0, 1.0] {
                    var arc = Path()
                    for step in 0...32 {
                        let offset = arcHalfHeight * (CGFloat(step) / 16 - 1)
                        let x = sqrt(max(0, radius * radius - offset * offset))
                        let point = CGPoint(
                            x: center.x + direction * x,
                            y: center.y + offset
                        )
                        if step == 0 { arc.move(to: point) } else { arc.addLine(to: point) }
                    }
                    context.stroke(arc, with: .color(.secondary.opacity(0.28)), lineWidth: 0.8)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if events.isEmpty {
                orbitAttribute(
                    title: "时间线",
                    value: L10n.text("暂无记录"),
                    systemImage: "clock",
                    side: .left
                )
                .frame(width: sideWidth)
                .position(x: center.x - radius - Self.orbitLabelGap - sideWidth / 2, y: center.y)
            } else {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    let side: GalaxyOrbitSide = index.isMultiple(of: 2) ? .left : .right
                    let direction: CGFloat = side == .left ? -1 : 1
                    let offset = (CGFloat(index / 2) - CGFloat(rows - 1) / 2) * spacing
                    let pointX = center.x + direction
                        * sqrt(max(0, radius * radius - offset * offset))
                    let selected = index == selectedTimelineIndex

                    Circle()
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.65))
                        .frame(width: selected ? 9 : 6, height: selected ? 9 : 6)
                        .position(x: pointX, y: center.y + offset)
                        .allowsHitTesting(false)

                    orbitAttribute(
                        title: "\(model.timelinePage * Self.timelinePageSize + index + 1) · \(timelineSource(for: event))",
                        value: event.date.formatted(date: .abbreviated, time: .shortened),
                        systemImage: selected ? "circle.fill" : "circle",
                        side: side,
                        lineLimit: 2,
                        action: {
                            withAnimation(selectionAnimation) {
                                selectedTimelineIndex = index
                            }
                        }
                    )
                    .frame(width: sideWidth)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(selected ? 0.65 : 0), lineWidth: 1)
                    }
                    .position(
                        x: center.x + direction * (radius + Self.orbitLabelGap + sideWidth / 2),
                        y: center.y + offset
                    )
                }
            }
        }
    }

    private func orbitConnectorGuide(
        canvasSize: CGSize,
        radius: CGFloat,
        verticalOffsets: [CGFloat]
    ) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for offset in verticalOffsets {
                let horizontal = sqrt(max(0, radius * radius - offset * offset))
                for direction in [-1.0, 1.0] {
                    let start = CGPoint(
                        x: center.x + horizontal * direction,
                        y: center.y + offset
                    )
                    let end = CGPoint(
                        x: center.x + (radius + Self.orbitLabelGap - 6) * direction,
                        y: center.y + offset
                    )
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(.secondary.opacity(0.32)), lineWidth: 0.75)
                    context.fill(
                        Path(ellipseIn: CGRect(x: start.x - 2, y: start.y - 2, width: 4, height: 4)),
                        with: .color(.primary.opacity(0.5))
                    )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func orbitAttribute(
        title: String,
        value: String,
        systemImage: String,
        side: GalaxyOrbitSide,
        lineLimit: Int = 1,
        action: (() -> Void)? = nil
    ) -> some View {
        if let action {
            Button(action: action) {
                orbitAttributeContent(
                    title: title,
                    value: value,
                    systemImage: systemImage,
                    appBundleID: nil,
                    side: side,
                    lineLimit: lineLimit,
                    interactive: true
                )
            }
            .buttonStyle(.plain)
            .help(value)
        } else {
            orbitAttributeContent(
                title: title,
                value: value,
                systemImage: systemImage,
                appBundleID: nil,
                side: side,
                lineLimit: lineLimit,
                interactive: false
            )
        }
    }

    /// 「来源应用」卡带真实应用图标的重载
    @ViewBuilder
    private func orbitAttribute(
        title: String,
        value: String,
        systemImage: String,
        appBundleID: String?,
        side: GalaxyOrbitSide
    ) -> some View {
        orbitAttributeContent(
            title: title,
            value: value,
            systemImage: systemImage,
            appBundleID: appBundleID,
            side: side,
            lineLimit: 1,
            interactive: false
        )
    }

    private func orbitAttributeContent(
        title: String,
        value: String,
        systemImage: String,
        appBundleID: String?,
        side: GalaxyOrbitSide,
        lineLimit: Int,
        interactive: Bool
    ) -> some View {
        HStack(spacing: 9) {
            if side == .right {
                orbitIcon(systemImage: systemImage, appBundleID: appBundleID)
                    .accessibilityHidden(true)
            }

            VStack(alignment: side == .left ? .trailing : .leading, spacing: 3) {
                Text(L10n.text(title))
                    .font(.system(size: chromeSize(2), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.system(size: chromeSize(), weight: .semibold))
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .multilineTextAlignment(side == .left ? .trailing : .leading)
            }

            if side == .left {
                orbitIcon(systemImage: systemImage, appBundleID: appBundleID)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: 56,
            alignment: side == .left ? .trailing : .leading
        )
        .glassEffect(
            interactive ? .regular.interactive() : .regular,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    /// 轨道卡图标：来源应用卡用真实 App 图标，其余用符号
    @ViewBuilder
    private func orbitIcon(systemImage: String, appBundleID: String?) -> some View {
        if let nsImage = SourceAppIcon.nsImage(bundleID: appBundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private func selectionActions(_ entry: GalaxyEntry) -> some View {
        let isClipboardEntry: Bool = {
            if case .clipboard = entry { return true }
            return false
        }()
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if model.isTimelineVisible, case .library = entry {
                    Button {
                        withAnimation(selectionAnimation) {
                            model.isTimelineVisible = false
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glassProminent)
                    .help("返回词条属性")

                    Button {
                        withAnimation(selectionAnimation) {
                            model.timelinePage -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.timelinePage == 0)
                    .help("查看较新的记录")

                    Text("\(model.timelinePage + 1) / \(model.timelinePageCount)")
                        .font(.system(size: chromeSize(-1)).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(selectionAnimation) {
                            model.timelinePage += 1
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.timelinePage + 1 >= model.timelinePageCount)
                    .help("查看更早的记录")

                    if let urlString = selectedTimelineEvent?.url,
                       let url = URL(string: urlString) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "link")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .help("打开这次记录的来源网页")
                    }
                } else {
                    Button {
                        watcher.copyText(entry.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glassProminent)
                    .help("复制全文")

                    switch entry {
                    case .library(let clip):
                        Button {
                            editingClip = clip
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .help("编辑词条")
                    case .clipboard(let clipboard):
                        Button {
                            promote(clipboard)
                        } label: {
                            Image(systemName: promotedIDs.contains(clipboard.id)
                                ? "checkmark.circle.fill" : "plus.circle.fill")
                                .foregroundStyle(
                                    promotedIDs.contains(clipboard.id) ? .green : .accentColor
                                )
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .disabled(promotedIDs.contains(clipboard.id))
                        .help(promotedIDs.contains(clipboard.id) ? L10n.text("已入库") : L10n.text("收入词库"))
                    }

                    if let urlString = entry.url, let url = URL(string: urlString) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "link")
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.glass)
                        .help("打开来源网页")
                    }

                    Button(role: .destructive) {
                        deletingEntry = entry
                    } label: {
                        // 与列表一致：词库为删除，剪贴板为移除
                        Image(systemName: isClipboardEntry ? "xmark.circle" : "trash")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .help(isClipboardEntry ? L10n.text("移除剪贴板记录") : L10n.text("删除词条"))
                    .accessibilityLabel(isClipboardEntry ? L10n.text("移除剪贴板记录") : L10n.text("删除词条"))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.source == .clipboard ? L10n.text("剪贴板操作")
                : model.isTimelineVisible ? L10n.text("时间线操作") : L10n.text("词条操作")
        )
    }

    private func promote(_ entry: ClipboardEntry) {
        do {
            guard let clip = try watcher.promote(entry) else { return }
            promotedIDs.insert(entry.id)
            ToastController.shared.show(clip.count > 1 ? L10n.format("已入库（第 %d 次）", clip.count) : L10n.text("已收入词库"))
        } catch {
            ToastController.shared.show(L10n.format("入库失败：%@", error.localizedDescription))
        }
    }

    private func timelineSource(for event: ClipEvent) -> String {
        let appName = event.appName ?? L10n.text("未知来源")
        guard let urlString = event.url,
              let host = URL(string: urlString)?.host else {
            return appName
        }
        return "\(appName) · \(host)"
    }
}
