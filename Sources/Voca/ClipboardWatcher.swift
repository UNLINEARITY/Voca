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
    let date: Date

    var isText: Bool { text != nil }

    static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// 剪贴板监听：文本条目持久化（去重置顶，≤200 条）；图片/文件仅内存展示
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let maxEntries = 200
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

    init(store: ClipStore) {
        self.store = store
        let stored = UserDefaults.standard.object(forKey: Self.defaultsKey)
        _isEnabled = Published(
            initialValue: stored == nil ? true : UserDefaults.standard.bool(forKey: Self.defaultsKey)
        )
        lastChangeCount = NSPasteboard.general.changeCount
        entries = store.loadClipboardEntries()
        if isEnabled { start() }
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

    private func poll() {
        guard isEnabled, !CaptureEngine.isSimulatingCopy else { return }
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // 密码管理器约定：带 ConcealedType 标记的保密条目不记录
        if let types = pasteboard.types,
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        {
            return
        }

        let app = NSWorkspace.shared.frontmostApplication

        // 1) 文本：直接记录 + 持久化（不去重）
        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        {
            let entry = ClipboardEntry(
                id: UUID(),
                text: String(text.prefix(10_000)),
                image: nil,
                fileNames: nil,
                appName: app?.localizedName,
                appBundleID: app?.bundleIdentifier,
                date: Date()
            )
            entries.insert(entry, at: 0)
            trimIfNeeded()
            store.saveClipboardEntry(entry)
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
                    date: Date()
                )
            )
        }
    }

    private func appendEphemeral(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    // MARK: - 操作

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        store.deleteClipboardEntry(id: entry.id)
    }

    func clear() {
        entries.removeAll()
        store.clearClipboardEntries()
    }
}

// MARK: - 剪贴板历史窗口

struct ClipboardHistoryView: View {
    @EnvironmentObject private var watcher: ClipboardWatcher
    @EnvironmentObject private var store: ClipStore
    @State private var promotedIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if watcher.entries.isEmpty {
                    Text(
                        watcher.isEnabled
                            ? "暂无剪贴板记录\n复制的内容会出现在这里；点 ➕ 将文本收入词库"
                            : "剪贴板记录已关闭\n可在菜单栏 ❝ 图标中开启"
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
                        watcher.clear()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(watcher.entries.isEmpty)
                }
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content(entry)

            HStack(spacing: 8) {
                Label(entry.appName ?? "未知来源", systemImage: "app.dashed")
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
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
                    watcher.remove(entry)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("移除")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func content(_ entry: ClipboardEntry) -> some View {
        if let text = entry.text {
            Text(text)
                .font(.system(size: 13))
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
        } else if let files = entry.fileNames {
            Label(
                files.count == 1 ? files[0] : "\(files.count) 个文件",
                systemImage: "doc.on.doc.fill"
            )
            .font(.system(size: 13))
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
        guard let text = entry.text else { return }
        do {
            // 入库时间 = 复制时间；入库后保留剪贴板记录
            try store.insert(
                text: text,
                appName: entry.appName,
                bundleID: entry.appBundleID,
                date: entry.date
            )
            ToastController.shared.show("已加入词库")
            promotedIDs.insert(entry.id)
        } catch {
            ToastController.shared.show("入库失败：\(error.localizedDescription)")
        }
    }
}
