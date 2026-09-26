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

/// 右下角非激活轻提示：不抢焦点、2 秒自动消失、自动跟随所有空间
final class ToastController {
    static let shared = ToastController()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String) {
        if Thread.isMainThread {
            _show(message, isSave: false)
        } else {
            DispatchQueue.main.async { self._show(message, isSave: false) }
        }
    }

    /// Animate only confirmed saves; other toasts keep their original quiet appearance.
    func showSaved(_ message: String) {
        if Thread.isMainThread {
            _show(message, isSave: true)
        } else {
            DispatchQueue.main.async { self._show(message, isSave: true) }
        }
    }

    private func _show(_ message: String, isSave: Bool) {
        hideWorkItem?.cancel()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hostView = NSHostingView(rootView: ToastView(
            message: message, isSave: isSave, reduceMotion: reduceMotion
        ))

        let contentSize = hostView.fittingSize

        let panel = acquirePanel()
        panel.contentView = hostView

        var targetOrigin = CGPoint.zero
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            targetOrigin = CGPoint(
                x: visible.maxX - contentSize.width - 24,
                y: visible.minY + 24
            )
            panel.setFrame(NSRect(origin: targetOrigin, size: contentSize), display: true)
        }
        if isSave {
            panel.alphaValue = 0
            if !reduceMotion {
                panel.setFrameOrigin(CGPoint(x: targetOrigin.x, y: targetOrigin.y - 10))
            }
        } else {
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
        if isSave {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0.12 : 0.42
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                if !reduceMotion { panel.animator().setFrameOrigin(targetOrigin) }
            }
        }

        let work = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func acquirePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        self.panel = panel
        return panel
    }
}

private struct ToastView: View {
    let message: String
    let isSave: Bool
    let reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        HStack(spacing: 7) {
            if isSave {
                if !reduceMotion {
                    ZStack {
                        ForEach(0..<3) { index in
                            Capsule()
                                .fill(.primary.opacity(0.9))
                                .frame(width: index == 1 ? 20 : 13, height: 2.5)
                                .offset(x: settled ? 13 : -9, y: CGFloat(index - 1) * 6)
                                .opacity(settled ? 0 : 0.95)
                                .shadow(color: .accentColor.opacity(0.55), radius: 3)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .animation(.easeInOut(duration: 0.58), value: settled)
                }
                ZStack {
                    Circle().fill(.regularMaterial)
                    Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 1.3)
                    Text("V").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .frame(width: 24, height: 24)
                .scaleEffect(reduceMotion || settled ? 1 : 0.6)
                .shadow(color: .accentColor.opacity(settled ? 0.4 : 0), radius: settled ? 7 : 0)
                .animation(.spring(response: 0.58, dampingFraction: 0.65), value: settled)
            }
            Text(message)
                .lineLimit(3)
        }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .floatingSurface()
            .frame(maxWidth: 320)
            .fixedSize()
            .onAppear {
                guard isSave, !reduceMotion else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { settled = true }
            }
    }
}
