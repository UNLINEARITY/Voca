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
import ImageIO
import SwiftUI

/// 一条剪贴板历史：文本可入库；文本与图片持久化，文件仅会话内展示
struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let text: String?
    let isImage: Bool
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

/// 剪贴板监听：文本与图片持久化（启动载入最近 2000 条）；文件仅会话内展示
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
    private let imageQueue = DispatchQueue(label: "local.voca.Voca.clipboard-images", qos: .utility)
    private var pendingImages: [UUID: (type: NSPasteboard.PasteboardType, data: Data)] = [:]
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

        // 图片优先于附带文字，但文件 URL 不作为图片保存。
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if fileURLs.isEmpty,
           let representation = Self.imageRepresentation(on: pasteboard),
           NSImage(data: representation.data) != nil
        {
            let entry = ClipboardEntry(
                id: UUID(), text: nil, isImage: true, fileNames: nil,
                appName: app?.localizedName, appBundleID: app?.bundleIdentifier,
                url: nil, date: Date()
            )
            entries.insert(entry, at: 0)
            pendingImages[entry.id] = representation
            imageQueue.async { [storage = store.imageStorage, weak self] in
                let saved = storage.saveClipboardImage(entry, type: representation.type.rawValue, data: representation.data)
                Task { @MainActor [weak self] in
                    self?.pendingImages.removeValue(forKey: entry.id)
                    if !saved { self?.entries.removeAll { $0.id == entry.id } }
                }
            }
            return
        }

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
                isImage: false,
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
        if !fileURLs.isEmpty {
            appendEphemeral(
                ClipboardEntry(
                    id: UUID(),
                    text: nil,
                    isImage: false,
                    fileNames: fileURLs.map(\.lastPathComponent),
                    appName: app?.localizedName,
                    appBundleID: app?.bundleIdentifier,
                    url: nil,
                    date: Date()
                )
            )
            return
        }
    }

    static func imageRepresentation(on pasteboard: NSPasteboard) -> (type: NSPasteboard.PasteboardType, data: Data)? {
        // 保留实际写入的编码，而不是通过 NSImage 重新编码。
        let supported: Set<NSPasteboard.PasteboardType> = [
            .png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("public.gif")
        ]
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types where supported.contains(type) {
                if let data = item.data(forType: type), !data.isEmpty { return (type, data) }
            }
        }
        return nil
    }

    func imagePreview(for id: UUID) async -> NSImage? {
        let pending = pendingImages[id]?.data
        return await withCheckedContinuation { continuation in
            imageQueue.async { [storage = store.imageStorage] in
                let data = pending ?? storage.loadClipboardImage(id: id)?.data
                let image: NSImage?
                if let data,
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 160,
                       kCGImageSourceCreateThumbnailWithTransform: true
                   ] as CFDictionary) {
                    image = NSImage(cgImage: thumbnail, size: .zero)
                } else {
                    image = nil
                }
                continuation.resume(returning: image)
            }
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
        pendingImages.removeValue(forKey: entry.id)
        if entry.isImage {
            imageQueue.async { [storage = store.imageStorage] in storage.deleteClipboardImage(id: entry.id) }
        } else {
            store.deleteClipboardEntry(id: entry.id)
        }
    }

    func clear() {
        entries.removeAll()
        pendingImages.removeAll()
        store.clearClipboardEntries()
        imageQueue.async { [storage = store.imageStorage] in storage.clearClipboardImages() }
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
        guard entry.isImage else { return }
        if let pending = pendingImages[entry.id] {
            writeImageToPasteboard(type: pending.type, data: pending.data)
            return
        }
        let changeCountAtClick = NSPasteboard.general.changeCount
        imageQueue.async { [storage = store.imageStorage, weak self] in
            let image = storage.loadClipboardImage(id: entry.id)
            Task { @MainActor [weak self] in
                guard let self, self.entries.contains(where: { $0.id == entry.id }),
                      NSPasteboard.general.changeCount == changeCountAtClick else { return }
                guard let image else {
                    ToastController.shared.show("图片读取失败")
                    return
                }
                self.writeImageToPasteboard(type: .init(image.type), data: image.data)
            }
        }
    }

    private func writeImageToPasteboard(type: NSPasteboard.PasteboardType, data: Data) {
        let pasteboard = NSPasteboard.general
        guard Self.writeImage(type: type, data: data, on: pasteboard) else {
            ToastController.shared.show("图片复制失败")
            return
        }
        lastChangeCount = pasteboard.changeCount
        ToastController.shared.show("已复制")
    }

    @discardableResult
    static func writeImage(type: NSPasteboard.PasteboardType, data: Data, on pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: type)
    }
}

// MARK: - 剪贴板历史窗口

struct ClipboardHistoryView: View {
    @EnvironmentObject private var watcher: ClipboardWatcher
    @AppStorage("listFontSize") private var listFontSize = Typography.listDefault
    @State private var promotedIDs: Set<UUID> = []
    @State private var expandedIDs: Set<UUID> = []
    @State private var truncatedIDs: Set<UUID> = []
    @State private var deletingEntry: ClipboardEntry?
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Group {
                if watcher.entries.isEmpty {
                    ContentUnavailableView(
                        watcher.isEnabled ? "暂无剪贴板记录" : "剪贴板记录已关闭",
                        systemImage: "clipboard",
                        description: Text(
                            watcher.isEnabled
                                ? "复制的内容会出现在这里；点行尾的加号按钮可收入词库。"
                                : "可在菜单栏 Voca 图标或设置页中开启。"
                        )
                    )
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
                        Label("清空剪贴板", systemImage: "trash")
                    }
                    .disabled(watcher.entries.isEmpty)
                }
            }
            .confirmationDialog(
                "移除这条剪贴板记录？",
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
                Button("清空（不可恢复）", role: .destructive) {
                    watcher.clear()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将移除全部剪贴板历史，包括未载入的记录和图片；不影响词库")
            }
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let expanded = expandedIDs.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            content(entry, expanded: expanded)

            HStack(spacing: 8) {
                SourceAppIcon.label(name: entry.appName, bundleID: entry.appBundleID)
                Spacer()
                Text(Self.historyTimeText(entry.date))
                    .lineLimit(1)
                if entry.isText, truncatedIDs.contains(entry.id) {
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
                if entry.isText || entry.isImage {
                    Button {
                        watcher.copyToPasteboard(entry)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(entry.isImage ? "复制图片" : "复制全文")
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
                    .help(promoted ? "已入库" : "收入词库")
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
            if let urlString = entry.url, URL(string: urlString) != nil {
                SourceLinkText(urlString: urlString)
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
                .background(
                    TruncationProbe(
                        text: text,
                        fontSize: listFontSize,
                        maxLines: 5,
                        isTruncated: truncationBinding(entry.id)
                    )
                )
        } else if let files = entry.fileNames {
            Label(
                files.count == 1 ? files[0] : "\(files.count) 个文件",
                systemImage: "doc.on.doc.fill"
            )
            .font(.system(size: listFontSize))
            .lineLimit(1)
            .foregroundStyle(.secondary)
        } else if entry.isImage {
            ClipboardImagePreview(id: entry.id)
        }
    }

    private struct ClipboardImagePreview: View {
        @EnvironmentObject private var watcher: ClipboardWatcher
        let id: UUID
        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: 64)
            .clipShape(RoundedRectangle(cornerRadius: Radius.inline, style: .continuous))
            .task(id: id) { image = await watcher.imagePreview(for: id) }
        }
    }

    /// 历史时间：今天显时刻，昨天标注“昨天”，更早带日期；均不带秒
    private static func historyTimeText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "昨天 " + time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 该行文本是否被行数上限截断（决定是否显示展开按钮）
    private func truncationBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { truncatedIDs.contains(id) },
            set: { truncated in
                if truncated {
                    truncatedIDs.insert(id)
                } else {
                    truncatedIDs.remove(id)
                }
            }
        )
    }

    private func save(_ entry: ClipboardEntry) {
        do {
            // 入库时间 = 复制时间；同文本合并计数；入库后保留剪贴板记录
            guard let clip = try watcher.promote(entry) else { return }
            ToastController.shared.show(clip.count > 1 ? "已入库（第 \(clip.count) 次）" : "已收入词库")
            promotedIDs.insert(entry.id)
        } catch {
            ToastController.shared.show("入库失败：\(error.localizedDescription)")
        }
    }
}
