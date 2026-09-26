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

/// 查词结果的处理结论（纯逻辑，可单测）：
/// 词典命中 → 词条卡；未命中但可翻译（短语/句子/中文）→ 系统翻译；否则忽略
enum LookupOutcome: Equatable {
    case card(DictionaryLookupResult)
    case translate(text: String, direction: TranslationDirection)
    case ignored
}

/// 浮窗内容模型：词条卡 或 翻译视图
enum LookupContent {
    case card(DictionaryLookupResult)
    case translation(original: String, direction: TranslationDirection)
}

/// 光标旁的查词/翻译浮窗：非激活面板，点外部任意处消失。
///
/// 入口（共用 `handleText`）：
/// - 全局快捷键（走 CaptureEngine 捕获管线，同保存流程）
/// - 系统服务「用 Voca 查词」（右键 → 服务，由系统直接递来选中文本）
///
/// 展示策略：词典优先（单词/短语/术语/缩写，含词形变体解析），
/// 未命中但含字母或汉字的文本走系统翻译（英↔中双向）；
/// 「收入词库」走 ClipStore 合并保存，译文自动写入备注。
@MainActor
final class LookupPopupController: NSObject {
    static let shared = LookupPopupController()

    private var panel: NSPanel?
    private var content: LookupContent?
    private var saveContext: (appName: String?, bundleID: String?, url: String?)?

    private override init() {
        super.init()
    }

    // MARK: - 入口

    /// 查词/翻译决策（纯逻辑）：不可翻译 → 忽略；词典命中 → 卡片；否则 → 翻译
    nonisolated static func outcome(
        for raw: String, service: DictionaryService = .shared
    ) -> LookupOutcome {
        guard DictionaryService.isTranslatable(raw) else { return .ignored }
        if let result = service.lookup(raw) {
            return .card(result)
        }
        return .translate(
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            direction: TranslationDirection.forText(raw)
        )
    }

    /// 快捷键/服务入口：文本来自 CaptureEngine 或系统服务（含来源与 URL 溯源）
    func handleText(
        _ raw: String, appName: String?, bundleID: String?, url: String?
    ) {
        let item: LookupContent
        switch Self.outcome(for: raw) {
        case .card(let result):
            item = .card(result)
        case .translate(let text, let direction):
            item = .translation(original: text, direction: direction)
        case .ignored:
            return
        }
        saveContext = (appName, bundleID, url)
        show(content: item, allowSave: true)
    }

    /// 词库列表双击查看：纯查词/翻译浮窗，无「收入词库」按钮
    /// （词条已在库中，避免译文覆盖用户手写备注）
    func handleViewOnly(_ raw: String) {
        let item: LookupContent
        switch Self.outcome(for: raw) {
        case .card(let result):
            item = .card(result)
        case .translate(let text, let direction):
            item = .translation(original: text, direction: direction)
        case .ignored:
            return
        }
        show(content: item, allowSave: false)
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

    private func show(content: LookupContent, allowSave: Bool) {
        self.content = content
        let hostView = NSHostingView(
            rootView: LookupPopupView(
                content: content,
                allowSave: allowSave,
                onSave: { [weak self] note in self?.saveToLibrary(note: note) }
            )
        )
        hostView.autoresizingMask = [.width, .height]

        let panel = acquirePanel()
        installDismissMonitors()
        panel.contentView = hostView

        let cursor = NSEvent.mouseLocation
        let visibleFrame = (NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.popupFrame(
            cursor: cursor,
            size: hostView.fittingSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 点击面板外部（任意 App）即消失，ESC 亦可关闭；监视器常驻，仅在面板可见时
    /// 生效，回调内不做拆除，避免在自身回调里同步移除监视器。
    private func installDismissMonitors() {
        guard dismissGlobalMonitor == nil, dismissLocalMonitor == nil, escapeMonitor == nil
        else { return }
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
        // 非激活面板只有自身为 key window 时才会收到本地按键（如从词库双击打开后
        // 点进浮窗），因此 ESC 作为补充入口，与星图的 ESC 行为对齐
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { self?.closeOnEscape() == true }
            return handled ? nil : event
        }
    }

    private var dismissGlobalMonitor: Any?
    private var dismissLocalMonitor: Any?
    private var escapeMonitor: Any?

    private func closeOnEscape() -> Bool {
        guard let panel, panel.isVisible, NSApp.keyWindow === panel else { return false }
        panel.orderOut(nil)
        return true
    }

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

    /// 浮窗「收入词库」：与 ⌥⇧S 相同的合并保存（同文本计数 +1 置顶）；
    /// 翻译模式下译文由视图经 `note` 传入，自动写入备注栏
    private func saveToLibrary(note: String?) {
        guard let content else { return }
        let text: String
        switch content {
        case .card(let result):
            text = result.entry.word
        case .translation(let original, _):
            text = original
        }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = saveContext ?? (nil, nil, nil)
        do {
            _ = try AppModel.shared.store.save(
                text: text,
                appName: context.appName,
                bundleID: context.bundleID,
                url: context.url,
                note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote
            )
        } catch {
            ToastController.shared.show("保存失败：\(error.localizedDescription)")
        }
    }
}

/// 浮窗内容：词条卡或翻译视图 + 底部「收入词库」按钮
private struct LookupPopupView: View {
    let content: LookupContent
    var allowSave = true
    let onSave: (String?) -> Void
    @AppStorage("popupFontSize") private var popupFontSize = Typography.popupDefault
    @AppStorage("popupWidth") private var popupWidth = 400.0
    @State private var saved = false
    @State private var translationResult: String?

    var body: some View {
        VStack(spacing: 8) {
            switch content {
            case .card(let result):
                DictionaryCardView(result: result)
            case .translation(let original, let direction):
                VStack(alignment: .leading, spacing: 4) {
                    Text("原文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(original)
                        .font(.system(size: Typography.derived(popupFontSize, offset: 1)))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                TranslatorView(text: original, direction: direction) { result in
                    translationResult = result
                }
                // 朗读英文侧：英→中读原文，中→英读译文
                speakRow(
                    for: direction == .englishToChinese
                        ? original : (translationResult ?? "")
                )
            }
            if allowSave {
                Divider()
                HStack {
                    Button {
                        guard !saved else { return }
                        saved = true
                        onSave(translationResult)
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
        }
        .padding(12)
        .frame(width: popupWidth, alignment: .leading)
        .floatingSurface()
    }

    /// 英/美发音按钮（仅对非空英文文本显示）
    private func speakRow(for englishText: String) -> some View {
        Group {
            if !englishText.isEmpty {
                HStack(spacing: 10) {
                    ForEach(SpeechAccent.allCases, id: \.rawValue) { accent in
                        Button {
                            SpeechService.shared.speak(englishText, accent: accent)
                        } label: {
                            Label(
                                accent == .british ? "英" : "美",
                                systemImage: "speaker.wave.2"
                            )
                            .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .help(accent == .british ? "英音朗读" : "美音朗读")
                    }
                    Spacer()
                }
            }
        }
    }
}
