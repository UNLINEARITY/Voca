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
    @AppStorage(DisplayLanguage.preferenceKey) private var displayLanguage = DisplayLanguage.system.rawValue
    @AppStorage("listFontSize") private var listFontSize = Typography.listDefault
    @AppStorage("popupFontSize") private var popupFontSize = Typography.popupDefault
    @AppStorage("popupWidth") private var popupWidth = 400.0
    @AppStorage("popupReadingHeight") private var readingHeight = 148.0
    @AppStorage("lookupAutoSpeakEnabled") private var lookupAutoSpeak = false

    private var databaseURL: URL { ClipStore.defaultURL() }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                appearanceSection
                dictionarySection
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
            Picker("语言", selection: $displayLanguage) {
                Text("跟随系统").tag(DisplayLanguage.system.rawValue)
                Text("English").tag(DisplayLanguage.english.rawValue)
                Text("简体中文").tag(DisplayLanguage.simplifiedChinese.rawValue)
            }
            .pickerStyle(.menu)
            SharedToggleRows()
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            fontSizeRow("列表字号", value: $listFontSize, caption: "应用于词库与剪贴板列表、时间线及编辑面板")
            fontSizeRow("浮窗字号", value: $popupFontSize, caption: "应用于查词与翻译浮窗")
            settingSliderRow(
                "浮窗宽度", value: $popupWidth, range: 360...560,
                caption: "查词与翻译浮窗的宽度（360–560pt），高度随内容自适应"
            )
            settingSliderRow(
                "阅读区高度", value: $readingHeight, range: 120...480,
                caption: "释义与学习区块的阅读区高度；浮窗总高 = 固定框架 + 此值，内容超出则滚动"
            )
            previewRow
        }
    }

    private func fontSizeRow(_ title: String, value: Binding<Double>, caption: String) -> some View {
        settingSliderRow(title, value: value, range: Typography.range, caption: caption)
    }

    /// 内嵌实时预览：示例词 inspect（带词根/家族/短语/同义词全区块），
    /// 宽度与字号设置即时生效；窗口不够宽时可拖宽查看完整宽度
    @ViewBuilder
    private var previewRow: some View {
        if let result = DictionaryService.shared.lookup("inspect") {
            VStack(alignment: .leading, spacing: 6) {
                Text("预览（示例词 inspect · 发音按钮可直接试听）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DictionaryCardView(result: result)
                    .frame(maxWidth: popupWidth, alignment: .leading)
            }
            .padding(.vertical, 2)
        }
    }

    private func settingSliderRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, caption: String,
        unit: String = "pt"
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.text(title))
                Spacer()
                Slider(value: value, in: range, step: 1)
                    .frame(width: 240)
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(L10n.text(caption))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 词典

    private var dictionarySection: some View {
        Section("词典") {
            Toggle(isOn: $lookupAutoSpeak) {
                Label("查词后自动发音", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.switch)
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
            LabeledContent("作者") {
                HStack(spacing: 10) {
                    Link("UNLINEARITY", destination: URL(string: "https://github.com/UNLINEARITY")!)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Link(
                        "unlinearity@gmail.com",
                        destination: URL(string: "mailto:unlinearity@gmail.com")!
                    )
                }
            }
            LabeledContent("版权") {
                Text("© 2026 UNLINEARITY")
            }
            LabeledContent("许可证") {
                Link(
                    "AGPL-3.0-or-later",
                    destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!
                )
            }
            if let meta = DictionaryService.shared.meta {
                LabeledContent("内嵌词典") {
                    Text(L10n.format("%d 条 · %@（%@）", meta.entries, meta.source, meta.license))
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
            Text("本程序为自由软件，基于 GNU AGPL-3.0-or-later 许可发布；© 2026 UNLINEARITY")
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
        panel.nameFieldStringValue = L10n.format("Voca-导出-%@.md", formatter.string(from: Date()))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
            ToastController.shared.show(L10n.format("已导出：%@", url.lastPathComponent))
        } catch {
            ToastController.shared.show(L10n.format("导出失败：%@", error.localizedDescription))
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
            ToastController.shared.show(L10n.format("已备份：%@", url.lastPathComponent))
        } catch {
            ToastController.shared.show(L10n.format("备份失败：%@", error.localizedDescription))
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
    @AppStorage("workspaceOpensOnCurrentScreen") private var opensOnCurrentScreen = true

    var body: some View {
        Toggle(isOn: $opensOnCurrentScreen) {
            Label("在当前屏幕打开工作区", systemImage: "display")
        }
        .toggleStyle(.switch)
        Toggle(isOn: $model.showsDockIcon) {
            Label("在 Dock 显示图标", systemImage: "dock.rectangle")
        }
        .toggleStyle(.switch)
        Toggle(isOn: $watcher.isEnabled) {
            Label("记录剪贴板历史", systemImage: "doc.on.clipboard")
        }
        .toggleStyle(.switch)
        Toggle(isOn: $model.threeFingerSaveEnabled) {
            Label("三指下滑保存（实验性）", systemImage: "hand.draw")
        }
        .toggleStyle(.switch)
        Toggle(isOn: $rootDecompositionEnabled) {
            Label("词根智能拆解", systemImage: "text.badget.star")
        }
        .toggleStyle(.switch)
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
        KeyboardShortcuts.Recorder(L10n.text("保存选中文字："), name: .saveSelection)
        KeyboardShortcuts.Recorder(L10n.text("查词 / 翻译："), name: .lookupWord)
        KeyboardShortcuts.Recorder(L10n.text("打开工作区："), name: .openGalaxy)
    }
}
