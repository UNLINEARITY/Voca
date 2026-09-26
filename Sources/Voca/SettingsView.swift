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
import KeyboardShortcuts
import SwiftUI

/// 工作区「设置」标签页：与词库/剪贴板页同构——NavigationStack + 原生标题，
/// 内容用系统设置同款的 Form(.grouped) 分组。与菜单栏设置项双入口共存。
struct SettingsView: View {
    @EnvironmentObject private var store: ClipStore

    @State private var stats: LibraryInfo.Stats?
    @State private var databaseBytes: Int64 = 0
    @State private var confirmingClearLibrary = false
    @AppStorage("listFontSize") private var listFontSize = Typography.listDefault
    @AppStorage("popupFontSize") private var popupFontSize = Typography.popupDefault

    private var databaseURL: URL { ClipStore.defaultURL() }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                appearanceSection
                shortcutSection
                librarySection
                databaseSection
                aboutSection
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .confirmationDialog(
                "清空全部词条？",
                isPresented: $confirmingClearLibrary,
                titleVisibility: .visible
            ) {
                Button("清空词库（不可恢复）", role: .destructive) {
                    store.deleteAll()
                    refreshInfo()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除全部词条与时间线事件；剪贴板历史不受影响")
            }
        }
        .task { refreshInfo() }
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section("通用") {
            SharedToggleRows()
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            fontSizeRow("列表字号", value: $listFontSize, caption: "应用于词库与剪贴板列表、时间线及编辑面板")
            fontSizeRow("浮窗字号", value: $popupFontSize, caption: "应用于查词与翻译浮窗")
        }
    }

    private func fontSizeRow(_ title: String, value: Binding<Double>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Slider(value: value, in: Typography.range, step: 1)
                    .frame(width: 150)
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        Section("快捷键") {
            SharedShortcutRows()
        }
    }

    // MARK: - 词库管理

    private var librarySection: some View {
        Section("词库管理") {
            if let stats {
                LabeledContent("词条数") { Text("\(stats.clips)") }
                LabeledContent("累计保存次数") { Text("\(stats.saves)") }
                LabeledContent("时间线事件") { Text("\(stats.events)") }
                LabeledContent("剪贴板历史条目") { Text("\(stats.clipboardEntries)") }
            } else {
                Text("统计读取中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    exportMarkdown()
                } label: {
                    Label("导出 Markdown…", systemImage: "square.and.arrow.down")
                }
                .disabled(store.clips.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirmingClearLibrary = true
                } label: {
                    Label("清空词库…", systemImage: "trash")
                }
                .disabled(store.clips.isEmpty)
            }
        }
    }

    // MARK: - 数据库

    private var databaseSection: some View {
        Section("数据库") {
            VStack(alignment: .leading, spacing: 4) {
                Text("位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(databaseURL.path)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("占用空间") {
                Text(LibraryInfo.formattedBytes(databaseBytes))
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Button {
                backupDatabase()
            } label: {
                Label("备份…", systemImage: "externaldrive.badge.timemachine")
            }
            Text("备份生成运行中安全的紧凑快照（单文件 SQLite，含最近保存）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本") {
                Text(
                    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "0.1.0"
                )
            }
            if let meta = DictionaryService.shared.meta {
                LabeledContent("内嵌词典") {
                    Text("\(meta.entries) 条 · \(meta.source)（\(meta.license)）")
                }
                LabeledContent("词典数据") {
                    if let url = URL(string: meta.sourceURL) {
                        Link(meta.sourceURL, destination: url)
                    } else {
                        Text(meta.sourceURL)
                    }
                }
            }
            Text("查词与翻译完全离线：词典内嵌于应用，翻译与发音使用系统能力")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 操作

    private func refreshInfo() {
        let url = databaseURL
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = LibraryInfo.stats(databaseURL: url)
            let bytes = LibraryInfo.databaseBytes(databaseURL: url)
            DispatchQueue.main.async {
                self.stats = stats
                self.databaseBytes = bytes
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

    private func backupDatabase() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "voca-backup-\(formatter.string(from: Date())).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LibraryInfo.backup(databaseURL: databaseURL, to: url)
            ToastController.shared.show("已备份：\(url.lastPathComponent)")
        } catch {
            ToastController.shared.show("备份失败：\(error.localizedDescription)")
        }
    }

}

// MARK: - 双入口共用控件

/// 菜单栏面板与工作区设置页共用的三个开关行：
/// 标签、图标与三指下滑状态文案都只维护一处，两个入口不再各自漂移。
struct SharedToggleRows: View {
    @ObservedObject private var model = AppModel.shared
    @EnvironmentObject private var watcher: ClipboardWatcher
    @AppStorage("rootDecompositionEnabled") private var rootDecompositionEnabled = true

    var body: some View {
        Toggle(isOn: $model.showsDockIcon) {
            Label("在 Dock 显示图标", systemImage: "dock.rectangle")
        }
        Toggle(isOn: $watcher.isEnabled) {
            Label("记录剪贴板历史", systemImage: "doc.on.clipboard")
        }
        Toggle(isOn: $model.threeFingerSaveEnabled) {
            Label("三指下滑保存（实验性）", systemImage: "hand.draw")
        }
        Toggle(isOn: $rootDecompositionEnabled) {
            Label("词根智能拆解", systemImage: "text.badget.star")
        }
        if model.threeFingerSaveEnabled {
            Text(model.gestureStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 菜单栏面板与工作区设置页共用的快捷键录制行（标签与顺序只维护一处）
struct SharedShortcutRows: View {
    var body: some View {
        KeyboardShortcuts.Recorder("保存选中文字：", name: .saveSelection)
        KeyboardShortcuts.Recorder("查词 / 翻译：", name: .lookupWord)
        KeyboardShortcuts.Recorder("打开工作区：", name: .openGalaxy)
    }
}
