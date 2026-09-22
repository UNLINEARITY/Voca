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

// MARK: - 球面条目

struct GalaxyItem {
    let clipId: Int64
    let label: String
    let fontSize: CGFloat
    let clip: Clip
    let position: SIMD3<Double> // 单位球面坐标
}

// MARK: - 球模型（旋转/惯性/自转/命中）

@MainActor
final class GalaxyModel: ObservableObject {
    static let maxItems = 400
    private static let baseAutoRotate: Double = 0.06 // rad/s 空闲自转

    @Published private(set) var items: [GalaxyItem] = []
    @Published var selectedClip: Clip?

    /// 字号全局缩放（滚轮/捏合调节，持久化）
    var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: "galaxyFontScale") }
    }

    init() {
        fontScale = UserDefaults.standard.object(forKey: "galaxyFontScale") as? Double
            ?? 1.0
    }

    func zoom(by factor: Double) {
        fontScale = (fontScale * factor).clamped(to: 0.5...2.5)
    }

    var yaw: Double = 0
    var pitch: Double = 0
    private var yawVelocity = GalaxyModel.baseAutoRotate
    private var pitchVelocity: Double = 0

    private var lastFrameTime: Double?
    private var lastDrag: (point: CGPoint, time: Double)?
    // 上一帧投影结果（主线程读写，点击命中用）
    var hitTargets: [(item: GalaxyItem, center: CGPoint)] = []

    func rebuild(from clips: [Clip]) {
        let sampled: [Clip]
        if clips.count > Self.maxItems {
            sampled = Array(
                clips
                    .sorted { ($0.count, $0.lastSeenAt) > ($1.count, $1.lastSeenAt) }
                    .prefix(Self.maxItems)
            )
            ToastController.shared.show("星图显示前 \(Self.maxItems) 条（按频次与最近度）")
        } else {
            sampled = clips
        }

        let n = sampled.count
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        var result: [GalaxyItem] = []
        result.reserveCapacity(n)
        for (index, clip) in sampled.enumerated() {
            // 斐波那契球面格点：均匀无聚簇
            let y = 1.0 - 2.0 * (Double(index) + 0.5) / Double(n)
            let r = sqrt(max(0, 1 - y * y))
            let theta = goldenAngle * Double(index)
            let label = Self.displayLabel(clip.text)
            result.append(
                GalaxyItem(
                    clipId: clip.id ?? 0,
                    label: label,
                    fontSize: Self.fontSize(for: clip.count),
                    clip: clip,
                    position: SIMD3(r * cos(theta), y, r * sin(theta))
                )
            )
        }
        items = result
        selectedClip = nil
    }

    func refreshSelection(in clips: [Clip]) {
        guard let selected = selectedClip, let id = selected.id else { return }
        selectedClip = clips.first { $0.id == id }
    }

    // MARK: 帧推进

    func step(now: Double) {
        let dt = min(0.05, lastFrameTime.map { now - $0 } ?? 1.0 / 60.0)
        lastFrameTime = now

        yaw += yawVelocity * dt
        pitch += pitchVelocity * dt
        pitch = pitch.clamped(to: -1.35...1.35)

        // 惯性衰减；yaw 缓慢回归自转基速，pitch 归零
        yawVelocity = Self.baseAutoRotate
            + (yawVelocity - Self.baseAutoRotate) * pow(0.05, dt)
        pitchVelocity *= pow(0.02, dt)
    }

    func rotatedPosition(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        // 先绕 Y 轴（yaw），再绕 X 轴（pitch）
        let x1 = p.x * cy + p.z * sy
        let z1 = -p.x * sy + p.z * cy
        let y2 = p.y * cp - z1 * sp
        let z2 = p.y * sp + z1 * cp
        return SIMD3(x1, y2, z2)
    }

    // MARK: 拖拽

    func dragChanged(_ point: CGPoint, time: Double) {
        defer { lastDrag = (point, time) }
        guard let last = lastDrag else { return }
        let dx = Double(point.x - last.point.x)
        let dy = Double(point.y - last.point.y)
        let dt = max(0.008, time - last.time)
        yaw -= dx * 0.005
        pitch += dy * 0.005
        pitch = pitch.clamped(to: -1.35...1.35)
        yawVelocity = -dx * 0.005 / dt
        pitchVelocity = dy * 0.005 / dt
    }

    func dragEnded() {
        lastDrag = nil
        // 限制惯性上限，避免甩飞
        yawVelocity = yawVelocity.clamped(to: -4...4)
        pitchVelocity = pitchVelocity.clamped(to: -4...4)
    }

    // MARK: 命中

    func hitTest(_ point: CGPoint) -> GalaxyItem? {
        var best: (item: GalaxyItem, center: CGPoint, distance: CGFloat)?
        for target in hitTargets {
            let d = hypot(target.center.x - point.x, target.center.y - point.y)
            let tolerance = target.item.fontSize + 10
            if d < tolerance, d < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (target.item, target.center, d)
            }
        }
        return best?.item
    }

    // MARK: - 映射

    /// 字号 = 频次：13pt 起步，对数增长封顶 30pt
    static func fontSize(for count: Int) -> CGFloat {
        13 + min(17.0, log2(Double(max(count, 1))) * 4.5)
    }

    /// 展示标签：首行、折叠空白、截断 14 字符
    static func displayLabel(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let collapsed = first.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        return collapsed.count > 14 ? String(collapsed.prefix(14)) + "…" : collapsed
    }
}

// MARK: - 全屏窗口控制器

@MainActor
final class GalaxyWindowController {
    static let shared = GalaxyWindowController()
    private var window: NSWindow?
    private var eventMonitor: Any?
    private(set) var model = GalaxyModel()

    var isOpen: Bool { window != nil }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        model.rebuild(from: AppModel.shared.store.clips)

        let contentView = GalaxyView(model: model)
            .environmentObject(AppModel.shared.store)
            .environmentObject(AppModel.shared.clipboardWatcher)
        let w = NSWindow(
            contentRect: NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 直接设 contentView 而非 contentViewController：
        // 后者会把窗口自适应到 SwiftUI 视图的理想尺寸（Canvas 无固有尺寸 → 缩成一小块）
        w.contentView = NSHostingView(rootView: contentView)
        // 显式撑满屏幕，居中铺开
        w.setFrame(NSScreen.main?.visibleFrame ?? w.frame, display: true)
        // 透明窗口：桌面可见，液态玻璃球体悬浮其上
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.identifier = NSUserInterfaceItemIdentifier("voca.galaxy")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .magnify]
        ) { [weak self] event in
            guard let self, self.window != nil else { return event }
            switch event.type {
            case .keyDown where event.keyCode == 53: // ESC
                if self.model.selectedClip != nil {
                    self.model.selectedClip = nil
                } else {
                    // 必须异步：在监视器回调内同步 removeMonitor 会导致
                    // 监视器对象在调用中途被释放 → objc_release 段错误
                    DispatchQueue.main.async {
                        GalaxyWindowController.shared.close()
                    }
                }
                return nil
            case .scrollWheel:
                let delta = event.scrollingDeltaY
                if delta != 0 {
                    self.model.zoom(by: pow(1.15, delta))
                }
                return nil
            case .magnify:
                self.model.zoom(by: 1 + event.magnification * 1.2)
                return nil
            default:
                return event
            }
        }
    }

    func close() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        window?.close()
        window = nil
    }
}

// MARK: - 星图视图

struct GalaxyView: View {
    @ObservedObject var model: GalaxyModel
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @State private var editingClip: Clip?
    @State private var timelineEvents: [ClipEvent] = []

    var body: some View {
        ZStack {
            // 液态玻璃球体：材质模糊桌面，文字浮于其上
            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) * 0.36
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .white.opacity(0.12), radius: 40)
                    // 左上高光，玻璃质感
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.28), .clear],
                                center: UnitPoint(x: 0.32, y: 0.28),
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    // 边缘光
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                }
                .frame(width: radius * 2, height: radius * 2)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                }
            }

            VStack {
                topBar
                Spacer()
                hintBar
            }

            if let clip = model.selectedClip {
                HStack(alignment: .top, spacing: 0) {
                    Spacer()
                    detailPanel(clip)
                        .padding(24)
                }
            }
        }
        .background(.clear)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    model.dragChanged(
                        value.location,
                        time: Date().timeIntervalSinceReferenceDate
                    )
                }
                .onEnded { _ in model.dragEnded() }
        )
        .onTapGesture { location in
            if let item = model.hitTest(location) {
                model.selectedClip = item.clip
            } else {
                model.selectedClip = nil
            }
        }
        .onChange(of: model.selectedClip) { _, clip in
            timelineEvents = clip.map { store.events(for: $0) } ?? []
        }
        .sheet(item: $editingClip) { clip in
            EditClipSheet(clip: clip) { text, note in
                store.update(clip, text: text, note: note)
                model.rebuild(from: store.clips)
                if let id = clip.id {
                    model.selectedClip = store.clips.first { $0.id == id }
                }
            }
        }
    }

    // MARK: 顶部/底部提示

    private var topBar: some View {
        HStack(spacing: 12) {
            Label("Voca 星图", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.7), radius: 2)
            Text("\(model.items.count) 条")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .shadow(color: .black.opacity(0.7), radius: 2)
            Spacer()
            Button {
                GalaxyWindowController.shared.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.7), radius: 2)
            }
            .buttonStyle(.plain)
            .help("退出星图（ESC）")
        }
        .padding(20)
    }

    private var hintBar: some View {
        Text("拖拽旋转 · 滚轮/捏合缩放字号 · 点击词条查看详情 · ESC 退出")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.45))
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(.bottom, 18)
    }

    // MARK: 详情面板（时间线内嵌直出）

    private func detailPanel(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if let note = clip.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            HStack(spacing: 8) {
                Label(clip.appName ?? "未知来源", systemImage: "app.dashed")
                if clip.count > 1 {
                    Text("×\(clip.count)")
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                Text(clip.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let urlString = clip.url, let url = URL(string: urlString) {
                Text(urlString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture { NSWorkspace.shared.open(url) }
            }

            Divider()

            Text("时间线 · \(clip.count) 次")
                .font(.caption)
                .foregroundStyle(.secondary)

            if timelineEvents.isEmpty {
                Text("暂无事件（早于时间线功能）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(timelineEvents) { event in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                                    Text(event.appName ?? "未知来源")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let urlString = event.url, let url = URL(string: urlString) {
                                    Image(systemName: "link")
                                        .onTapGesture { NSWorkspace.shared.open(url) }
                                        .help(urlString)
                                }
                            }
                            .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            Divider()

            HStack(spacing: 14) {
                Button {
                    editingClip = clip
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                Button {
                    watcher.copyText(clip.text)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Spacer()
                Button {
                    model.selectedClip = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭（ESC）")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))
        }
        .padding(16)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Canvas 绘制

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        now: Double
    ) {
        model.step(now: now)

        // 极淡晕影：压暗四角保证白字可读，桌面保持透明
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .radialGradient(
                Gradient(colors: [.clear, .black.opacity(0.22)]),
                center: CGPoint(x: rect.midX, y: rect.midY),
                startRadius: min(rect.width, rect.height) * 0.35,
                endRadius: max(rect.width, rect.height) * 0.72
            )
        )

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.36
        let selectedId = model.selectedClip?.id

        // 背面→前面排序绘制
        var targets: [(item: GalaxyItem, center: CGPoint)] = []
        let sorted = model.items
            .map { ($0, model.rotatedPosition($0.position)) }
            .sorted { $0.1.z < $1.1.z }

        for (item, p) in sorted {
            let depth = (p.z + 1) / 2 // 0=背面 1=正面
            let alpha = 0.15 + 0.85 * depth
            let scale = 0.72 + 0.28 * depth
            // 正交投影：位置严格锁定球面轮廓
            let point = CGPoint(x: center.x + p.x * radius, y: center.y - p.y * radius)
            let isSelected = item.clipId == selectedId
            let font = Font.system(
                size: item.fontSize * scale * model.fontScale,
                weight: isSelected ? .semibold : .regular
            )

            // 贴面：沿球面经线（东向切线）倾斜 + 边缘透视压缩
            let qr = hypot(item.position.x, item.position.z) // 该点水平半径
            let east: SIMD3<Double> = qr > 1e-6
                ? SIMD3(item.position.z / qr, 0, -item.position.x / qr)
                : SIMD3(1, 0, 0)
            let t = model.rotatedPosition(east)
            let angle = atan2(-t.y, t.x) // 屏幕坐标 y 翻转
            let compression = max(0.28, hypot(t.x, t.y)) // 切线投影长度 = 压缩比

            context.drawLayer { layer in
                layer.translateBy(x: point.x, y: point.y)
                layer.rotate(by: .radians(angle))
                layer.scaleBy(x: compression, y: 1)
                if isSelected {
                    layer.addFilter(.shadow(color: .yellow.opacity(0.85), radius: 12))
                    layer.draw(
                        Text(item.label).font(font).foregroundStyle(.yellow),
                        at: .zero
                    )
                } else {
                    // 前半球才画投影，减负
                    if depth > 0.5 {
                        layer.draw(
                            Text(item.label).font(font)
                                .foregroundStyle(.black.opacity(alpha * 0.5)),
                            at: CGPoint(x: 1, y: 1)
                        )
                    }
                    layer.draw(
                        Text(item.label).font(font).foregroundStyle(.white.opacity(alpha)),
                        at: .zero
                    )
                }
            }

            if depth > 0.25 {
                targets.append((item, point))
            }
        }
        model.hitTargets = targets
    }
}

// MARK: - 工具

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
