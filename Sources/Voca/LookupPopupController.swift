// Voca — a macOS menu bar app for saving selected text globally.
// Copyright (C) 2026 UNLINEARITY <https://github.com/UNLINEARITY>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// 查词结果的处理结论（纯逻辑，可单测）
enum LookupOutcome: Equatable {
    case show(DictionaryLookupResult)
    case ignored
}

/// 光标旁的词典浮窗：非激活面板，点外部任意处消失。
///
/// 两个入口共用 `handleText`：
/// - 全局快捷键（走 CaptureEngine 捕获管线，同保存流程）
/// - 系统服务「用 Voca 查词」（右键 → 服务，由系统直接递来选中文本）
///
/// 非单个英文单词或未命中词典时静默忽略；保存按钮走 ClipStore 合并保存。
@MainActor
final class LookupPopupController: NSObject {
    static let shared = LookupPopupController()

    private var panel: NSPanel?
    private var saveContext: (appName: String?, bundleID: String?, url: String?)?

    private override init() {
        super.init()
    }

    // MARK: - 入口

    /// 查词决策（纯逻辑）：非单词或未命中 → 忽略
    nonisolated static func outcome(for raw: String, service: DictionaryService = .shared) -> LookupOutcome {
        guard DictionaryService.isLookupableWord(raw),
            let result = service.lookup(raw)
        else { return .ignored }
        return .show(result)
    }

    /// 快捷键入口：文本来自 CaptureEngine（含来源与 URL 溯源）
    func handleText(
        _ raw: String, appName: String?, bundleID: String?, url: String?
    ) {
        switch Self.outcome(for: raw) {
        case .show(let result):
            saveContext = (appName, bundleID, url)
            show(result: result)
        case .ignored:
            break
        }
    }

    /// 系统服务入口：Info.plist NSServices → NSMessage "lookupWordService"。
    /// 选中文本由系统经粘贴板递入；来源 App 取前台应用，浏览器 URL 溯源
    /// 涉及 AppleScript，放后台线程收集。
    @objc func lookupWordService(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pboard.string(forType: .string) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let frontApp = NSWorkspace.shared.frontmostApplication
            let url = BrowserTabURL.current(bundleID: frontApp?.bundleIdentifier)
            DispatchQueue.main.async {
                self.handleText(
                    text,
                    appName: frontApp?.localizedName,
                    bundleID: frontApp?.bundleIdentifier,
                    url: url
                )
            }
        }
    }

    // MARK: - 面板

    private func show(result: DictionaryLookupResult) {
        let hostView = NSHostingView(
            rootView: LookupPopupView(
                result: result,
                onSave: { [weak self] in self?.saveToLibrary() }
            )
        )
        let contentSize = hostView.fittingSize

        let panel = acquirePanel()
        installDismissMonitors()
        panel.contentView = hostView

        let cursor = NSEvent.mouseLocation
        let visibleFrame = (NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.popupFrame(
            cursor: cursor,
            size: contentSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 点击面板外部（任意 App）即消失；监视器常驻，仅在面板可见时生效，
    /// 回调内不做拆除，避免在自身回调里同步移除监视器。
    private func installDismissMonitors() {
        guard dismissGlobalMonitor == nil, dismissLocalMonitor == nil else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfClickedOutside() }
        }
        dismissGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: handler
        )
        dismissLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            handler(event)
            return event
        }
    }

    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?

    private func dismissIfClickedOutside() {
        guard let panel, panel.isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            panel.orderOut(nil)
        }
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        self.panel = panel
        return panel
    }

    /// 浮窗定位：默认悬在光标上方 18pt，水平居中；上方放不下改到下方，
    /// 两侧贴边内收，最终完全夹在可见区域内。
    nonisolated static func popupFrame(cursor: CGPoint, size: CGSize, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 6
        let gap: CGFloat = 18

        var origin = CGPoint(
            x: cursor.x - size.width / 2,
            y: cursor.y + gap
        )
        // 上方空间不足且下方更宽裕 → 翻到光标下方
        if origin.y + size.height > visibleFrame.maxY - margin,
            cursor.y - gap - size.height >= visibleFrame.minY + margin {
            origin.y = cursor.y - gap - size.height
        }
        // 水平夹进可见区
        origin.x = min(
            max(origin.x, visibleFrame.minX + margin),
            visibleFrame.maxX - margin - size.width
        )
        // 垂直夹进可见区（极端小屏兜底）
        origin.y = min(
            max(origin.y, visibleFrame.minY + margin),
            max(visibleFrame.minY + margin, visibleFrame.maxY - margin - size.height)
        )
        return NSRect(origin: origin, size: size)
    }

    // MARK: - 保存

    /// 浮窗「收入词库」：走与 ⌥⇧S 相同的合并保存（同文本计数 +1 置顶）
    private func saveToLibrary() {
        guard let panel, panel.isVisible else { return }
        let word = (panel.contentView as? NSHostingView<LookupPopupView>)?
            .rootView.result.entry.word ?? ""
        guard !word.isEmpty else { return }
        let context = saveContext ?? (nil, nil, nil)
        do {
            _ = try AppModel.shared.store.save(
                text: word,
                appName: context.appName,
                bundleID: context.bundleID,
                url: context.url
            )
        } catch {
            ToastController.shared.show("保存失败：\(error.localizedDescription)")
        }
    }
}

/// 浮窗内容：词典卡 + 底部「收入词库」按钮
private struct LookupPopupView: View {
    let result: DictionaryLookupResult
    let onSave: () -> Void
    @State private var saved = false

    var body: some View {
        VStack(spacing: 8) {
            DictionaryCardView(result: result, showsBackground: false)
            Divider()
            HStack {
                Button {
                    guard !saved else { return }
                    saved = true
                    onSave()
                } label: {
                    Label(
                        saved ? "已入库" : "收入词库",
                        systemImage: saved ? "checkmark.circle.fill" : "plus.circle"
                    )
                    .font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(saved)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
