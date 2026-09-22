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
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let store: ClipStore
    let clipboardWatcher: ClipboardWatcher

    private init() {
        do {
            store = try ClipStore()
        } catch {
            fatalError("Voca: 无法打开数据库：\(error)")
        }
        clipboardWatcher = ClipboardWatcher(store: store)
    }

    func handleHotkey() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureEngine.shared.capture()
            DispatchQueue.main.async {
                AppModel.shared.handle(result)
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
                    ToastController.shared.show("第 \(clip.count) 次记录，已置顶\(suffix)")
                } else {
                    ToastController.shared.show("已保存\(suffix)")
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
        KeyboardShortcuts.onKeyUp(for: .saveSelection) {
            AppModel.shared.handleHotkey()
        }
    }
}

@main
struct VocaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // 首次启动给默认快捷键 ⌥⇧S，用户可随时在菜单栏改
        if KeyboardShortcuts.getShortcut(for: .saveSelection) == nil {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(.s, modifiers: [.option, .shift]),
                for: .saveSelection
            )
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.store)
                .environmentObject(model.clipboardWatcher)
        } label: {
            Image(systemName: "text.quote")
        }
        .menuBarExtraStyle(.window)

        Window("Voca 记录", id: "records") {
            RecordsView()
                .environmentObject(model.store)
                .environmentObject(model.clipboardWatcher)
        }
        .defaultSize(width: 560, height: 480)

        Window("剪贴板历史", id: "clipboard") {
            ClipboardHistoryView()
                .environmentObject(model.clipboardWatcher)
                .environmentObject(model.store)
        }
        .defaultSize(width: 520, height: 460)
    }
}

// MARK: - 菜单栏面板

struct MenuBarView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var watcher: ClipboardWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                Text("Voca").font(.headline)
                Spacer()
                Text("\(store.clips.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            KeyboardShortcuts.Recorder("保存快捷键：", name: .saveSelection)

            Toggle(isOn: $watcher.isEnabled) {
                Label("记录剪贴板历史", systemImage: "doc.on.clipboard")
            }

            Divider()

            Button {
                openWindow(id: "records")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("查看全部记录", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                openWindow(id: "clipboard")
                NSApp.activate(ignoringOtherApps: true)
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
}

// MARK: - 记录窗口

struct RecordsView: View {
    @EnvironmentObject private var store: ClipStore
    @State private var search = ""
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
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Voca 记录")
            .searchable(text: $search, placement: .toolbar, prompt: "搜索全文")
            .onChange(of: search) { _, newValue in
                store.reload(search: newValue)
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
                store.reload(search: search)
            }
            .sheet(item: $editingClip) { clip in
                EditClipSheet(clip: clip) { text, note in
                    store.update(clip, text: text, note: note)
                    store.reload(search: search)
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

    init(clip: Clip, onSave: @escaping (String, String?) -> Void) {
        self.clip = clip
        self.onSave = onSave
        _text = State(initialValue: clip.text)
        _note = State(initialValue: clip.note ?? "")
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑记录").font(.headline)

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
        .frame(width: 460, height: 440)
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
