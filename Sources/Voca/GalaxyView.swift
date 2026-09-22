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
import SwiftUI
import simd

// MARK: - 球面数据

struct GalaxyItem {
    let clipId: Int64
    let text: String
    let fontSize: CGFloat
    let clip: Clip
    let position: SIMD3<Float>
}

@MainActor
final class GalaxyModel: ObservableObject {
    static let maxItems = 400

    @Published private(set) var items: [GalaxyItem] = []
    @Published var selectedClip: Clip?
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: "galaxyFontScale") }
    }

    init() {
        fontScale = UserDefaults.standard.object(forKey: "galaxyFontScale") as? Double
            ?? 1.0
    }

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

        let count = sampled.count
        guard count > 0 else {
            items = []
            selectedClip = nil
            return
        }

        let goldenAngle = Float.pi * (3.0 - sqrt(5.0))
        items = sampled.enumerated().map { index, clip in
            let y = 1.0 - 2.0 * (Float(index) + 0.5) / Float(count)
            let horizontalRadius = sqrt(max(0, 1 - y * y))
            let theta = goldenAngle * Float(index)
            return GalaxyItem(
                clipId: clip.id ?? 0,
                text: Self.displayText(clip.text),
                fontSize: Self.fontSize(for: clip.count),
                clip: clip,
                position: SIMD3(
                    horizontalRadius * cos(theta),
                    y,
                    horizontalRadius * sin(theta)
                )
            )
        }
        selectedClip = nil
    }

    func zoom(by factor: Double) {
        fontScale = (fontScale * factor).clamped(to: 0.5...2.5)
    }

    static func fontSize(for count: Int) -> CGFloat {
        13 + min(17.0, log2(Double(max(count, 1))) * 4.5)
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
    private var model = GalaxyModel()

    var isOpen: Bool { window?.isVisible == true }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        model.rebuild(from: AppModel.shared.store.clips)
        let screenFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let window: NSWindow
        if let existingWindow = self.window {
            window = existingWindow
            window.setFrame(screenFrame, display: true)
            setGalaxyRendering(paused: false, in: window.contentView)
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
            window.contentView = NSHostingView(rootView: contentView)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.identifier = NSUserInterfaceItemIdentifier("voca.galaxy")
            self.window = window
        }

        installEventMonitor()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        removeEventMonitor()
        guard let window else { return }
        setGalaxyRendering(paused: true, in: window.contentView)
        model.selectedClip = nil
        window.orderOut(nil)
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.isOpen, event.keyCode == 53 else { return event }
            if self.model.selectedClip != nil {
                self.model.selectedClip = nil
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

private struct GalaxyView: View {
    @ObservedObject var model: GalaxyModel
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @State private var editingClip: Clip?
    @State private var timelineEvents: [ClipEvent] = []

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * 0.36

            ZStack {
                sphere(diameter: radius * 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                VStack {
                    topBar
                    Spacer()
                    hintBar
                }
                .padding(20)

                if let clip = model.selectedClip {
                    HStack {
                        Spacer()
                        detailPanel(
                            clip,
                            maximumHeight: min(geometry.size.height - 128, 680)
                        )
                        .padding(.trailing, 24)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: model.selectedClip?.id)
        }
        .background(.clear)
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

    private func sphere(diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .glassEffect(.clear, in: Circle())
                .padding(diameter * 0.03)

            GalaxyLensView()
                .clipShape(Circle())
                .padding(diameter * 0.03)
                .allowsHitTesting(false)

            if model.items.isEmpty {
                ContentUnavailableView(
                    "星图还是空的",
                    systemImage: "sparkles",
                    description: Text("保存一些文字后，它们会出现在这里。")
                )
                .frame(maxWidth: diameter * 0.56)
            } else {
                GalaxySphereView(model: model)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: 顶部与提示

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                    Text("Voca 星图")
                        .fontWeight(.semibold)
                    Text("\(model.items.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 15)
                .padding(.trailing, 17)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())

                Spacer()

                Button {
                    GalaxyWindowController.shared.close()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .help("退出星图（ESC）")
            }
        }
    }

    private var hintBar: some View {
        Text("拖拽旋转 · 滚轮/捏合缩放字号 · 点击词条查看详情 · ESC 退出")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: 详情面板

    private func detailPanel(_ clip: Clip, maximumHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(clip)

                    if let note = clip.note, !note.isEmpty {
                        noteSection(note)
                            .padding(.top, 16)
                    }

                    metadataSection(clip)
                        .padding(.vertical, 15)

                    Divider()

                    timelineSection
                        .padding(.top, 15)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }

            Divider()
                .padding(.horizontal, 18)

            detailActions(clip)
                .padding(18)
        }
        .frame(width: 390)
        .frame(maxHeight: maximumHeight)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private func detailHeader(_ clip: Clip) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("词条详情")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(clip.text)
                    .font(.title3.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Button {
                model.selectedClip = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help("关闭（ESC）")
        }
    }

    private func noteSection(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("注释", systemImage: "quote.opening")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(note)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func metadataSection(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(clip.appName ?? "未知来源", systemImage: "app.dashed")
                Label("保存 \(clip.count) 次", systemImage: "square.stack.3d.up")
                Spacer(minLength: 8)
                Text(clip.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let urlString = clip.url, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label {
                        Text(urlString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "link")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(urlString)
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(
                    "时间线",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(timelineEvents.count) 次记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            if timelineEvents.isEmpty {
                Text("暂无事件（早于时间线功能）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            } else {
                ForEach(Array(timelineEvents.enumerated()), id: \.offset) { index, event in
                    timelineRow(event, isLatest: index == 0, isLast: index == timelineEvents.count - 1)
                }
            }
        }
    }

    private func timelineRow(
        _ event: ClipEvent,
        isLatest: Bool,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isLatest ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                if !isLast {
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .frame(width: 1, height: 35)
                }
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(isLatest ? .semibold : .regular))
                HStack(spacing: 5) {
                    Text(event.appName ?? "未知来源")
                    if let urlString = event.url, let url = URL(string: urlString) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "link")
                        }
                        .buttonStyle(.plain)
                        .help(urlString)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 9)

            Spacer(minLength: 0)
        }
    }

    private func detailActions(_ clip: Clip) -> some View {
        HStack(spacing: 10) {
            Button {
                watcher.copyText(clip.text)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.glassProminent)

            Button {
                editingClip = clip
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .buttonStyle(.glass)

            Spacer()

            if let urlString = clip.url, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "link")
                }
                .buttonStyle(.glass)
                .help("打开来源网页")
            }
        }
    }

}

// MARK: - 工具

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
