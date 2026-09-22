import AppKit
import SwiftUI

/// 右下角非激活轻提示：不抢焦点、2 秒自动消失、自动跟随所有空间
final class ToastController {
    static let shared = ToastController()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String) {
        if Thread.isMainThread {
            _show(message)
        } else {
            DispatchQueue.main.async { self._show(message) }
        }
    }

    private func _show(_ message: String) {
        hideWorkItem?.cancel()

        let hostView = NSHostingView(rootView: ToastView(message: message))
        let contentSize = hostView.fittingSize

        let panel = acquirePanel()
        panel.contentView = hostView

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = CGPoint(
                x: visible.maxX - contentSize.width - 24,
                y: visible.minY + 24
            )
            panel.setFrame(NSRect(origin: origin, size: contentSize), display: true)
        }
        panel.orderFrontRegardless()

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

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .frame(maxWidth: 320)
            .fixedSize()
    }
}
