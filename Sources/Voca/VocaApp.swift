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
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension KeyboardShortcuts.Name {
    static let saveSelection = Self("saveSelection")
    // 保留旧标识，避免重置用户已录制的工作区快捷键。
    static let openGalaxy = Self("openGalaxy")
    static let lookupWord = Self("lookupWord")
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let store: ClipStore
    let clipboardWatcher: ClipboardWatcher

    /// Dock 图标偏好存储键
    static let showsDockIconKey = "showsDockIcon"
    static let threeFingerSaveKey = "threeFingerSaveEnabled"

    @Published private(set) var threeFingerSaveStatus: TrackpadGestureMonitor.Status = .off
    @Published var threeFingerSaveEnabled: Bool {
        didSet {
            guard oldValue != threeFingerSaveEnabled else { return }
            UserDefaults.standard.set(threeFingerSaveEnabled, forKey: Self.threeFingerSaveKey)
            TrackpadGestureMonitor.shared.setEnabled(threeFingerSaveEnabled)
        }
    }

    /// 在 Dock 显示应用图标;关闭只隐藏 Dock 图标,菜单栏与后台运行不受影响,不会退出
    @Published var showsDockIcon: Bool {
        didSet {
            guard oldValue != showsDockIcon else { return }
            UserDefaults.standard.set(showsDockIcon, forKey: Self.showsDockIconKey)
            NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
        }
    }

    private init() {
        do {
            store = try ClipStore()
        } catch {
            fatalError("Voca: 无法打开数据库：\(error)")
        }
        _showsDockIcon = Published(
            initialValue: UserDefaults.standard.object(forKey: Self.showsDockIconKey) == nil
                ? false
                : UserDefaults.standard.bool(forKey: Self.showsDockIconKey)
        )
        _threeFingerSaveEnabled = Published(
            initialValue: UserDefaults.standard.bool(forKey: Self.threeFingerSaveKey)
        )
        clipboardWatcher = ClipboardWatcher(store: store)
    }

    func startGestureMonitorIfNeeded() {
        TrackpadGestureMonitor.shared.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.threeFingerSaveStatus = status }
        }
        TrackpadGestureMonitor.shared.onSave = { [weak self] in
            MainActor.assumeIsolated {
                guard self?.threeFingerSaveEnabled == true else { return }
                self?.handleHotkey()
            }
        }
        if threeFingerSaveEnabled {
            TrackpadGestureMonitor.shared.setEnabled(true)
        }
    }

    func handleHotkey() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureEngine.shared.capture()
            DispatchQueue.main.async {
                AppModel.shared.handle(result)
            }
        }
    }

    /// 查词快捷键：同保存的捕获管线，但命中单词弹词典浮窗，非单词静默
    func handleLookupHotkey() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureEngine.shared.capture()
            DispatchQueue.main.async {
                switch result {
                case .success(let text, let appName, let bundleID, let url):
                    LookupPopupController.shared.handleText(
                        text, appName: appName, bundleID: bundleID, url: url
                    )
                case .emptySelection:
                    ToastController.shared.show("未检测到选中文本")
                case .notTrusted:
                    ToastController.shared.show("需要辅助功能权限，正在打开系统设置…")
                    CaptureEngine.shared.requestTrust()
                case .secureField:
                    ToastController.shared.show("已跳过安全输入框（密码）")
                }
            }
        }
    }

    private func handle(_ result: CaptureResult) {
        switch result {
        case .success(let text, let appName, let bundleID, let url):
            let capped = String(text.prefix(10_000))
            do {
                let clip = try store.save(
                    text: capped,
                    appName: appName,
                    bundleID: bundleID,
                    url: url
                )
                let suffix = appName.map { " · 来自 \($0)" } ?? ""
                if clip.count > 1 {
                    ToastController.shared.showSaved("第 \(clip.count) 次记录，已置顶\(suffix)")
                } else {
                    ToastController.shared.showSaved("已保存\(suffix)")
                }
            } catch {
                ToastController.shared.show("保存失败：\(error.localizedDescription)")
            }
        case .emptySelection:
            ToastController.shared.show("未检测到选中文本")
        case .notTrusted:
            ToastController.shared.show("需要辅助功能权限，正在打开系统设置…")
            CaptureEngine.shared.requestTrust()
        case .secureField:
            ToastController.shared.show("已跳过安全输入框（密码）")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = WorkspaceNavigation.shared
        AppModel.shared.startGestureMonitorIfNeeded()
        // 系统服务「用 Voca 查词」（右键 → 服务）的接收器
        NSApp.servicesProvider = LookupPopupController.shared
        KeyboardShortcuts.onKeyUp(for: .saveSelection) {
            AppModel.shared.handleHotkey()
        }
        KeyboardShortcuts.onKeyUp(for: .openGalaxy) {
            WorkspaceNavigation.shared.toggleLastWorkspace()
        }
        KeyboardShortcuts.onKeyUp(for: .lookupWord) {
            AppModel.shared.handleLookupHotkey()
        }
        // 调试/自动化入口：`open Voca.app --args --galaxy` 启动即打开星图
        if CommandLine.arguments.contains("--galaxy") {
            GalaxyWindowController.shared.open()
        }
    }

    /// Dock 模式下点击 Dock 图标：无可见窗口时激活并打开记录窗口
    func applicationShouldHandleReopen(
        _ application: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            WorkspaceNavigation.shared.openPanel(.library)
        }
        return true
    }
}

@main
struct VocaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // 启动即恢复 Dock 图标偏好(LSUIElement=true 仅决定初始形态,运行时可切换)
        let dockEnabled = UserDefaults.standard.object(forKey: AppModel.showsDockIconKey) != nil
            && UserDefaults.standard.bool(forKey: AppModel.showsDockIconKey)
        NSApplication.shared.setActivationPolicy(dockEnabled ? .regular : .accessory)
        // 首次启动给默认快捷键，用户可随时在菜单栏改
        if KeyboardShortcuts.getShortcut(for: .saveSelection) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.s, modifiers: [.option, .shift]),
                for: .saveSelection
            )
        }
        if KeyboardShortcuts.getShortcut(for: .openGalaxy) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.v, modifiers: [.option, .shift]),
                for: .openGalaxy
            )
        }
        if KeyboardShortcuts.getShortcut(for: .lookupWord) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.d, modifiers: [.option, .shift]),
                for: .lookupWord
            )
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.store)
                .environmentObject(model.clipboardWatcher)
        } label: {
            Image(nsImage: VocaMenuBarArtwork.image)
                .accessibilityLabel("Voca")
        }
        .menuBarExtraStyle(.window)

    }
}

// MARK: - 菜单栏面板

private enum VocaMenuBarArtwork {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()

            let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            rim.lineWidth = 1.4
            rim.stroke()

            let letter = NSBezierPath()
            letter.move(to: NSPoint(x: 5.1, y: 11.5))
            letter.line(to: NSPoint(x: 9, y: 5.2))
            letter.line(to: NSPoint(x: 12.9, y: 11.5))
            letter.lineWidth = 1.7
            letter.lineCapStyle = .round
            letter.lineJoinStyle = .round
            letter.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: VocaMenuBarArtwork.image)
                    .foregroundStyle(.secondary)
                Text("Voca").font(.headline)
                Spacer()
                Text("\(store.clips.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            KeyboardShortcuts.Recorder("保存快捷键：", name: .saveSelection)
            KeyboardShortcuts.Recorder("工作区快捷键：", name: .openGalaxy)
            KeyboardShortcuts.Recorder("查词快捷键：", name: .lookupWord)

            Toggle(isOn: $model.threeFingerSaveEnabled) {
                Label("三指下滑保存（实验性）", systemImage: "hand.draw")
            }
            if model.threeFingerSaveEnabled {
                Text(gestureStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $watcher.isEnabled) {
                Label("记录剪贴板历史", systemImage: "doc.on.clipboard")
            }

            Toggle(isOn: $model.showsDockIcon) {
                Label("在 Dock 显示图标", systemImage: "dock.rectangle")
            }

            Divider()

            Button {
                WorkspaceNavigation.shared.toggleGalaxy()
            } label: {
                Label("星图模式", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                WorkspaceNavigation.shared.openPanel(.library)
            } label: {
                Label("查看全部记录", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                WorkspaceNavigation.shared.openPanel(.clipboard)
            } label: {
                Label("剪贴板历史", systemImage: "clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Voca", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var gestureStatusText: String {
        switch model.threeFingerSaveStatus {
        case .off: return ""
        case .unavailable: return "当前系统不支持触控板监听；保存快捷键仍可使用。"
        case .waiting: return "等待内建或外接触控板；保存快捷键仍可使用。"
        case .ready: return "若与 App Exposé 冲突，请在系统设置中手动改为四指下滑或关闭该手势。"
        }
    }
}

// MARK: - 记录窗口

struct RecordsView: View {
    @EnvironmentObject private var store: ClipStore
    @State private var search = ""
    @State private var searchReloadTask: Task<Void, Never>?
    @State private var editingClip: Clip?
    @State private var timelineClip: Clip?
    @State private var deletingClip: Clip?
    @State private var confirmingClearAll = false

    var body: some View {
        NavigationStack {
            Group {
                if store.clips.isEmpty {
                    Text(
                        search.isEmpty
                            ? "还没有记录\n在任意 App 选中文字，按保存快捷键试试"
                            : "没有匹配的记录"
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.clips) { clip in
                        ClipRow(
                            clip: clip,
                            onEdit: { editingClip = clip },
                            onTimeline: { timelineClip = clip },
                            onDelete: { deletingClip = clip }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            editingClip = clip
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Voca 记录")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索全文")
            .onChange(of: search) { _, newValue in
                // 防抖 200ms：连续古键只触发一次后台查询，不卡输入
                searchReloadTask?.cancel()
                searchReloadTask = Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    store.reloadAsync(search: newValue)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportMarkdown()
                    } label: {
                        Label("导出 Markdown", systemImage: "square.and.arrow.down")
                    }
                    .disabled(store.clips.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmingClearAll = true
                    } label: {
                        Label("清空全部", systemImage: "trash")
                    }
                    .disabled(store.clips.isEmpty)
                }
            }
            .onAppear {
                store.reloadAsync(search: search)
            }
            .onDisappear {
                searchReloadTask?.cancel()
            }
            .sheet(item: $editingClip) { clip in
                EditClipSheet(clip: clip) { text, note in
                    store.update(clip, text: text, note: note)
                }
            }
            .sheet(item: $timelineClip) { clip in
                ClipTimelineSheet(clip: clip)
            }
            .confirmationDialog(
                "删除这条记录？",
                isPresented: .init(
                    get: { deletingClip != nil },
                    set: { if !$0 { deletingClip = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除（不可恢复）", role: .destructive) {
                    if let clip = deletingClip { store.delete(clip) }
                    deletingClip = nil
                }
                Button("取消", role: .cancel) {
                    deletingClip = nil
                }
            } message: {
                Text("将同时删除该记录的时间线事件")
            }
            .confirmationDialog(
                "清空全部记录？",
                isPresented: $confirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("清空全部（不可恢复）", role: .destructive) {
                    store.deleteAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将永久删除全部 \(store.clips.count) 条记录及其时间线")
            }
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "Voca-导出-\(formatter.string(from: Date())).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            ToastController.shared.show("已导出：\(url.lastPathComponent)")
        } catch {
            ToastController.shared.show("导出失败：\(error.localizedDescription)")
        }
    }
}

struct ClipRow: View {
    let clip: Clip
    var onEdit: () -> Void
    var onTimeline: () -> Void
    var onDelete: () -> Void
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clip.text)
                .font(.system(size: 13))
                .lineLimit(expanded ? nil : 5)
                .truncationMode(.tail)
                .textSelection(.enabled)

            // 备注浅灰显示，行数跟随备注本身（不截断）
            if let note = clip.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "收起" : "展开全文")
                Button {
                    watcher.copyText(clip.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制全文")
                Button {
                    onTimeline()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("时间线")
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // 来源网页：浅灰小字显示在来源行下方，点击打开
            if let urlString = clip.url, let url = URL(string: urlString) {
                Text(urlString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture {
                        NSWorkspace.shared.open(url)
                    }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let urlString = clip.url, let url = URL(string: urlString) {
                Button("打开来源网页") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("复制全文") {
                watcher.copyText(clip.text)
            }
            Button("时间线…") {
                onTimeline()
            }
            Button("编辑…") {
                onEdit()
            }
            Button("删除…", role: .destructive) {
                onDelete()
            }
        }
    }
}

/// 编辑记录：修改文本、添加备注
struct EditClipSheet: View {
    let clip: Clip
    let onSave: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var note: String
    /// 保存时是单个英文单词时携带词典结果（只读单行主键查询，init 内同步取）
    @State private var lookupResult: DictionaryLookupResult?

    init(clip: Clip, onSave: @escaping (String, String?) -> Void) {
        self.clip = clip
        self.onSave = onSave
        _text = State(initialValue: clip.text)
        _note = State(initialValue: clip.note ?? "")
        _lookupResult = State(
            initialValue: DictionaryService.shared.lookup(clip.text)
        )
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑记录").font(.headline)

            if let lookupResult {
                DictionaryCardView(result: lookupResult)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("内容").font(.caption).foregroundStyle(.secondary)
                editor(text: $text)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("备注（可选）").font(.caption).foregroundStyle(.secondary)
                editor(text: $note)
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                Spacer()
                Button("保存") {
                    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(text, trimmedNote.isEmpty ? nil : trimmedNote)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: lookupResult == nil ? 440 : 620)
        .onDisappear {
            SpeechService.shared.stop()
        }
    }

    /// 多行编辑框：与其他编辑区均分空间，内容过多时内部滚动
    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .frame(maxHeight: .infinity)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

/// 时间线子页面：某条记录的每次出现时间与来源
struct ClipTimelineSheet: View {
    let clip: Clip
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var events: [ClipEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间线 · 共 \(clip.count) 次记录")
                .font(.headline)

            Text(clip.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if events.isEmpty {
                Text("暂无事件记录\n（该条目早于时间线功能，仅保留了合并计数）")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(events) { event in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.formatted(date: .abbreviated, time: .standard))
                            Text(event.appName ?? "未知来源")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let urlString = event.url, let url = URL(string: urlString) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "link")
                            }
                            .buttonStyle(.borderless)
                            .help("打开来源网页：\(urlString)")
                        }
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.quaternary)
                    }
                    .font(.system(size: 13))
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 400, height: 460)
        .onAppear {
            events = store.events(for: clip)
        }
    }
}
