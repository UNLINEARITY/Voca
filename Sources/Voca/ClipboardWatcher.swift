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

/// 一条剪贴板历史：文本可入库并持久化；图片/文件仅会话内展示
struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let text: String?
    let image: NSImage?
    let fileNames: [String]?
    let appName: String?
    let appBundleID: String?
    var url: String?
    let date: Date

    var isText: Bool { text != nil }

    static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// 剪贴板监听：文本条目持久化（不去重，无上限保留；启动载入最近 2000 条）；图片/文件仅会话内展示
@MainActor
final class ClipboardWatcher: ObservableObject {
    private static let defaultsKey = "clipboardWatcherEnabled"

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private let store: ClipStore
    private var timer: Timer?
    private var lastChangeCount: Int
    /// 最近一条文本记录的时间(同文本短窗防抖用)
    private var lastTextEntryAt: Date?
    private var simulatedCopyObserver: NSObjectProtocol?
    /// 浏览器 URL 查询串行队列：慢查询自然排队，不堆积并发子进程
    private let browserURLQueue = DispatchQueue(label: "local.voca.Voca.browser-url", qos: .utility)

    init(store: ClipStore) {
        self.store = store
        let stored = UserDefaults.standard.object(forKey: Self.defaultsKey)
        _isEnabled = Published(
            initialValue: stored == nil ? true : UserDefaults.standard.bool(forKey: Self.defaultsKey)
        )
        lastChangeCount = NSPasteboard.general.changeCount
        entries = store.loadClipboardEntries()
        // ⌘C 降级取词结束后同步基准,模拟复制与恢复都不进历史
        simulatedCopyObserver = NotificationCenter.default.addObserver(
            forName: .simulatedCopyEnded, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                if notification.userInfo?["recordCurrent"] as? Bool == true {
                    self?.poll(force: true)
                } else {
                    self?.lastChangeCount = NSPasteboard.general.changeCount
                }
            }
        }
        if isEnabled { start() }
    }

    deinit {
        if let observer = simulatedCopyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll(force: Bool = false) {
        guard isEnabled else { return }
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        if CaptureEngine.isSimulatingCopy {
            // 模拟复制/恢复期间先不推进基准；结束时再决定同步或补记用户的新复制。
            return
        }
        guard force || count != lastChangeCount else { return }
        lastChangeCount = count

        // 密码管理器约定：带 ConcealedType 标记的保密条目不记录
        if let types = pasteboard.types,
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        {
            return
        }

        let app = NSWorkspace.shared.frontmostApplication

        // 1) 文本：直接记录 + 持久化；来自浏览器时后台补填当前标签页 URL。
        //    同一文本 2 秒内的重复写入(应用多阶段写剪贴板/连按 ⌘C)只记一次
        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        {
            let trimmed = String(text.prefix(10_000))
            if entries.first?.text == trimmed,
               let lastAt = lastTextEntryAt,
               Date().timeIntervalSince(lastAt) < 2
            {
                return
            }
            lastTextEntryAt = Date()
            let entry = ClipboardEntry(
                id: UUID(),
                text: trimmed,
                image: nil,
                fileNames: nil,
                appName: app?.localizedName,
                appBundleID: app?.bundleIdentifier,
                url: nil,
                date: Date()
            )
            entries.insert(entry, at: 0)
            store.saveClipboardEntry(entry)
            resolveBrowserURL(for: entry, bundleID: app?.bundleIdentifier)
            return
        }

        // 2) 文件（仅会话内展示）
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            appendEphemeral(
                ClipboardEntry(
                    id: UUID(),
                    text: nil,
                    image: nil,
                    fileNames: urls.map(\.lastPathComponent),
                    appName: app?.localizedName,
                    appBundleID: app?.bundleIdentifier,
                    url: nil,
                    date: Date()
                )
            )
            return
        }

        // 3) 图片（仅会话内展示）
        if let image = NSImage(pasteboard: pasteboard) {
            appendEphemeral(
                ClipboardEntry(
                    id: UUID(),
                    text: nil,
                    image: image,
                    fileNames: nil,
                    appName: app?.localizedName,
                    appBundleID: app?.bundleIdentifier,
                    url: nil,
                    date: Date()
                )
            )
        }
    }

    private func appendEphemeral(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
    }

    /// 后台查询浏览器标签页 URL，完成后回主线程补填该条记录（内存 + 持久层）。
    /// 条目在查询期间被删除时，补填静默跳过（UPDATE 命中 0 行）。
    private func resolveBrowserURL(for entry: ClipboardEntry, bundleID: String?) {
        guard BrowserTabURL.isSupportedBrowser(bundleID: bundleID) else { return }
        let entryID = entry.id
        browserURLQueue.async { [weak self] in
            guard let url = BrowserTabURL.current(bundleID: bundleID) else { return }
            Task { @MainActor in
                self?.applyResolvedURL(url, to: entryID)
            }
        }
    }

    private func applyResolvedURL(_ url: String, to id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].url = url
        store.updateClipboardEntryURL(id: id, url: url)
    }

    // MARK: - 操作

    /// 将文本历史收入词库，原剪贴板记录保持独立。
    func promote(_ entry: ClipboardEntry) throws -> Clip? {
        guard let text = entry.text else { return nil }
        return try store.save(
            text: text,
            appName: entry.appName,
            bundleID: entry.appBundleID,
            url: entry.url,
            date: entry.date
        )
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        store.deleteClipboardEntry(id: entry.id)
    }

    func clear() {
        entries.removeAll()
        store.clearClipboardEntries()
    }

    /// 把文本写回剪贴板（Voca 自己发起的写入不计入历史）
    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        // 同步基准：下一次轮询视为“无变化”，不产生新记录
        lastChangeCount = pasteboard.changeCount
        ToastController.shared.show("已复制")
    }

    /// 把历史条目写回剪贴板（文本或图片；不计入历史）
    func copyToPasteboard(_ entry: ClipboardEntry) {
        if let text = entry.text {
            copyText(text)
            return
        }
        guard let image = entry.image else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.writeObjects([image]) else { return }
        lastChangeCount = pasteboard.changeCount
        ToastController.shared.show("已复制")
    }
}

// MARK: - 剪贴板历史窗口

struct ClipboardHistoryView: View {
    @EnvironmentObject private var watcher: ClipboardWatcher
    @AppStorage("listFontSize") private var listFontSize = 13.0
    @State private var promotedIDs: Set<UUID> = []
    @State private var expandedIDs: Set<UUID> = []
    @State private var deletingEntry: ClipboardEntry?
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if watcher.entries.isEmpty {
                    Text(
                        watcher.isEnabled
                            ? "暂无剪贴板记录\n复制的内容会出现在这里；点 ➕ 将文本收入词库"
                            : "剪贴板记录已关闭\n可在菜单栏 Voca 图标中开启"
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(watcher.entries) { entry in
                        row(entry)
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("剪贴板历史")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(watcher.entries.isEmpty)
                }
            }
            .confirmationDialog(
                "移除这条记录？",
                isPresented: .init(
                    get: { deletingEntry != nil },
                    set: { if !$0 { deletingEntry = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("移除", role: .destructive) {
                    if let entry = deletingEntry { watcher.remove(entry) }
                    deletingEntry = nil
                }
                Button("取消", role: .cancel) {
                    deletingEntry = nil
                }
            } message: {
                Text("仅从剪贴板历史移除，不影响已入库的记录")
            }
            .confirmationDialog(
                "清空剪贴板历史？",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    watcher.clear()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除全部 \(watcher.entries.count) 条历史（不影响词库）")
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let expanded = expandedIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            content(entry, expanded: expanded)

            HStack(spacing: 8) {
                Label(entry.appName ?? "未知来源", systemImage: "app.dashed")
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
                if entry.isText {
                    Button {
                        if expanded {
                            expandedIDs.remove(entry.id)
                        } else {
                            expandedIDs.insert(entry.id)
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "收起" : "展开全文")
                }
                if entry.isText || entry.image != nil {
                    Button {
                        watcher.copyToPasteboard(entry)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制到剪贴板")
                }
                if entry.isText {
                    let promoted = promotedIDs.contains(entry.id)
                    Button {
                        save(entry)
                    } label: {
                        Image(systemName: promoted ? "checkmark.circle.fill" : "plus.circle.fill")
                            .foregroundStyle(promoted ? .green : .accentColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(promoted)
                    .help(promoted ? "已入库" : "加入词库")
                }
                Button {
                    deletingEntry = entry
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("移除")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // 来源网页：浅灰小字显示在来源行下方，点击打开
            if let urlString = entry.url, let url = URL(string: urlString) {
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
    }

    @ViewBuilder
    private func content(_ entry: ClipboardEntry, expanded: Bool) -> some View {
        if let text = entry.text {
            Text(text)
                .font(.system(size: listFontSize))
                .lineLimit(expanded ? nil : 5)
                .truncationMode(.tail)
                .textSelection(.enabled)
        } else if let files = entry.fileNames {
            Label(
                files.count == 1 ? files[0] : "\(files.count) 个文件",
                systemImage: "doc.on.doc.fill"
            )
            .font(.system(size: listFontSize))
            .lineLimit(1)
            .foregroundStyle(.secondary)
        } else if let image = entry.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 64)
                .cornerRadius(4)
        }
    }

    private func save(_ entry: ClipboardEntry) {
        do {
            // 入库时间 = 复制时间；同文本合并计数；入库后保留剪贴板记录
            guard let clip = try watcher.promote(entry) else { return }
            ToastController.shared.show(clip.count > 1 ? "已入库（第 \(clip.count) 次）" : "已加入词库")
            promotedIDs.insert(entry.id)
        } catch {
            ToastController.shared.show("入库失败：\(error.localizedDescription)")
        }
    }
}
