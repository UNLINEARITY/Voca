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
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case settings
    case library
    case clipboard

    var id: String { rawValue }
    /// 标签对应的星图档：设置 ↔ 检索，词库 ↔ 词库，剪贴板 ↔ 剪贴板
    var galaxySource: GalaxySource {
        switch self {
        case .settings: .search
        case .library: .library
        case .clipboard: .clipboard
        }
    }
}

private enum WorkspaceDestination: String {
    case galaxy
    case settings
    case library
    case clipboard
}

@MainActor
final class WorkspaceNavigation: ObservableObject {
    static let shared = WorkspaceNavigation()

    private static let destinationKey = "workspaceLastDestination"
    private static let panelTabKey = "workspaceLastPanelTab"

    @Published private(set) var tab = WorkspaceTab(
        rawValue: UserDefaults.standard.string(forKey: panelTabKey) ?? ""
    ) ?? .library
    private var lastDestination = WorkspaceDestination(
        rawValue: UserDefaults.standard.string(forKey: destinationKey) ?? ""
    ) ?? .galaxy
    private var panelWindow: NSWindow?
    private var transitionWindow: NSWindow?
    private var isTransitioning = false
    private var arrowMonitor: Any?

    private init() {
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleArrow(event) == true }
            return handled ? nil : event
        }
    }

    func openPanel(_ tab: WorkspaceTab) {
        guard !isTransitioning else { return }
        setTab(tab)
        if GalaxyWindowController.shared.isOpen {
            transition(toGalaxy: false, targetTab: tab)
        } else {
            let window = ensurePanelWindow()
            window.makeKeyAndOrderFront(nil)
            focusPanelContainer()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func toggleGalaxy() {
        guard !isTransitioning else { return }
        let galaxy = GalaxyWindowController.shared
        if galaxy.isActive {
            galaxy.close()
        } else if panelWindow?.isKeyWindow == true, NSApp.isActive {
            transition(toGalaxy: true)
        } else {
            galaxy.open()
        }
    }

    func toggleLastWorkspace() {
        guard !isTransitioning else { return }
        let galaxy = GalaxyWindowController.shared
        if galaxy.isActive {
            galaxy.close()
        } else if panelWindow?.isKeyWindow == true, NSApp.isActive {
            panelWindow?.orderOut(nil)
        } else {
            switch lastDestination {
            case .galaxy: galaxy.open()
            case .settings: openPanel(.settings)
            case .library: openPanel(.library)
            case .clipboard: openPanel(.clipboard)
            }
        }
    }

    func noteGalaxyOpened() {
        lastDestination = .galaxy
        UserDefaults.standard.set(lastDestination.rawValue, forKey: Self.destinationKey)
    }

    func setTab(_ newTab: WorkspaceTab) {
        let destination: WorkspaceDestination
        switch newTab {
        case .settings: destination = .settings
        case .library: destination = .library
        case .clipboard: destination = .clipboard
        }
        lastDestination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: Self.destinationKey)
        UserDefaults.standard.set(newTab.rawValue, forKey: Self.panelTabKey)
        guard newTab != tab else { return }
        tab = newTab
        focusPanelContainer()
    }

    func openGalaxyForPanel() {
        transition(toGalaxy: true)
    }

    /// 星图 → 工作区面板（星图顶栏「返回面板」与 ⇧⌥↑ 共用同一路径）
    func returnToPanel() {
        guard GalaxyWindowController.shared.isOpen else { return }
        transition(toGalaxy: false)
    }

    private func ensurePanelWindow() -> NSWindow {
        if let panelWindow { return panelWindow }
        let content = WorkspacePanelView()
            .environmentObject(AppModel.shared.store)
            .environmentObject(AppModel.shared.clipboardWatcher)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voca"
        window.identifier = NSUserInterfaceItemIdentifier("voca.workspace")
        window.contentView = WorkspaceHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        panelWindow = window
        return window
    }

    private func focusPanelContainer() {
        guard let panelWindow, let contentView = panelWindow.contentView else { return }
        panelWindow.makeFirstResponder(contentView)
    }

    private func handleArrow(_ event: NSEvent) -> Bool {
        let keys = event.modifierFlags.intersection([.shift, .option, .command, .control])
        let optionNavigation = keys == [.shift, .option]
        let galaxyAlias = keys == [.shift, .command]
        guard optionNavigation || galaxyAlias else { return false }
        guard !isTransitioning, !event.isARepeat, NSApp.isActive,
              NSApp.modalWindow == nil, let window = NSApp.keyWindow,
              window.attachedSheet == nil,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSTextField)
        else { return false }

        let galaxy = GalaxyWindowController.shared
        if window === galaxy.hostedWindow {
            if optionNavigation && event.keyCode == kVK_UpArrow {
                transition(toGalaxy: false)
                return true
            }
            if (optionNavigation || galaxyAlias)
                && (event.keyCode == kVK_LeftArrow || event.keyCode == kVK_RightArrow) {
                galaxy.switchSource(forward: event.keyCode == kVK_RightArrow)
                return true
            }
        } else if window === panelWindow, optionNavigation {
            if event.keyCode == kVK_DownArrow {
                transition(toGalaxy: true)
                return true
            }
            if event.keyCode == kVK_LeftArrow || event.keyCode == kVK_RightArrow {
                // 设置 ↔ 词库 ↔ 剪贴板 循环切换
                let order: [WorkspaceTab] = [.settings, .library, .clipboard]
                guard let index = order.firstIndex(of: tab) else { return false }
                let delta = event.keyCode == kVK_RightArrow ? 1 : order.count - 1
                setTab(order[(index + delta) % order.count])
                return true
            }
        }
        return false
    }

    private func transition(toGalaxy: Bool, targetTab: WorkspaceTab? = nil) {
        guard !isTransitioning else { return }
        let galaxy = GalaxyWindowController.shared
        let panel = ensurePanelWindow()
        let source = toGalaxy ? tab.galaxySource : galaxy.source
        if !toGalaxy {
            // 星图回面板：检索档回设置页，其余回对应列表
            let backTab: WorkspaceTab = switch source {
            case .clipboard: .clipboard
            case .search: .settings
            case .library: .library
            }
            setTab(targetTab ?? backTab)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isTransitioning = true

        let sphereFrame = galaxySphereFrame()
        let startFrame = toGalaxy ? panel.frame : sphereFrame
        let endFrame = toGalaxy ? sphereFrame : panel.frame
        if !reduceMotion {
            transitionWindow = makeGlassShell(frame: startFrame, sphere: !toGalaxy)
            animateGlassShell(to: endFrame, becomingSphere: toGalaxy)
        }

        if toGalaxy {
            galaxy.open(source: source, initiallyTransparent: true)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            focusPanelContainer()
            NSApp.activate(ignoringOtherApps: true)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if toGalaxy {
                panel.animator().alphaValue = 0
                galaxy.hostedWindow?.animator().alphaValue = 1
            } else {
                galaxy.hostedWindow?.animator().alphaValue = 0
                panel.animator().alphaValue = 1
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if toGalaxy {
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                    galaxy.hostedWindow?.makeKeyAndOrderFront(nil)
                } else {
                    galaxy.close()
                    panel.makeKeyAndOrderFront(nil)
                    self.focusPanelContainer()
                }
                self.transitionWindow?.close()
                self.transitionWindow = nil
                self.isTransitioning = false
            }
        }
    }

    private func galaxySphereFrame() -> NSRect {
        let frame = GalaxyWindowController.shared.hostedWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let tuning = GalaxyTuning.shared
        let diameter = min(frame.width, frame.height) * tuning.sphereScale * 2 * tuning.ringScale
        return NSRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private func makeGlassShell(frame: NSRect, sphere: Bool) -> NSWindow {
        let shell = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        shell.isOpaque = false
        shell.backgroundColor = .clear
        shell.hasShadow = true
        shell.ignoresMouseEvents = true
        shell.level = .floating
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.cornerRadius = sphere ? frame.height / 2 : Radius.panel
        glass.layer?.masksToBounds = true
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        glass.layer?.borderWidth = 1
        shell.contentView = glass
        shell.orderFrontRegardless()
        return shell
    }

    private func animateGlassShell(to frame: NSRect, becomingSphere: Bool) {
        guard let shell = transitionWindow, let layer = shell.contentView?.layer else { return }
        let oldRadius = layer.cornerRadius
        let newRadius = becomingSphere ? frame.height / 2 : Radius.panel
        let rounded = CABasicAnimation(keyPath: "cornerRadius")
        rounded.fromValue = oldRadius
        rounded.toValue = newRadius
        rounded.duration = 0.30
        rounded.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.cornerRadius = newRadius
        layer.add(rounded, forKey: "cornerRadius")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shell.animator().setFrame(frame, display: true)
        }
    }
}

private final class WorkspaceHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

private struct WorkspacePanelView: View {
    @ObservedObject private var navigation = WorkspaceNavigation.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("内容", selection: Binding(
                    get: { navigation.tab },
                    set: { navigation.setTab($0) }
                )) {
                    Text("设置").tag(WorkspaceTab.settings)
                    Text("词库").tag(WorkspaceTab.library)
                    Text("剪贴板").tag(WorkspaceTab.clipboard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
                Text("⇧⌥←→ 切换 · ⇧⌥↓ 星图")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    navigation.openGalaxyForPanel()
                } label: {
                    Label("星图", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .help("进入当前标签星图（⇧⌥↓）")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if navigation.tab == .settings {
                SettingsView()
            } else if navigation.tab == .library {
                RecordsView()
            } else {
                ClipboardHistoryView()
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
