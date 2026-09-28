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

import Foundation
import GRDB
import os

/// 一条保存记录：选中文本 + 来源 App + 时间
struct Clip: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clips"

    var id: Int64?
    var text: String
    var note: String?
    var appName: String?
    var appBundleID: String?
    var wordCount: Int
    var createdAt: Date
    /// 来源网页（浏览器保存时记录，可点击回源）
    var url: String?
    /// 同文本出现次数（去重合并）
    var count: Int
    /// 最近一次保存时间（列表置顶排序键）
    var lastSeenAt: Date
    /// text 的 FNV-1a 64 位哈希：合并查找的预筛键（命中后仍做全文比对，碰撞不影响正确性）
    var textHash: Int64

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// FNV-1a 64-bit（UTF-8 字节流），用于 idx_clips_textHash 预筛
    static func textHash(of text: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }
}

/// 一次保存事件（时间线条目）
struct ClipEvent: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clip_events"

    var id: Int64?
    var clipId: Int64
    var date: Date
    var appName: String?
    var appBundleID: String?
    var url: String?
}

final class ClipStore: ObservableObject {
    private let dbQueue: DatabaseQueue
    let imageStorage: ClipboardImageStorage
    @Published private(set) var clips: [Clip] = []

    private static let logger = Logger(subsystem: "local.voca.Voca", category: "store")
    /// 当前列表是否处于搜索过滤态(保存后的发布策略依赖它)
    private var currentSearch = ""
    /// 异步重载的代际计数:过期结果不得覆盖新结果
    private var reloadGeneration = 0

    /// 数据库位置：~/Library/Application Support/Voca/voca.sqlite
    /// 备份 = 退出 Voca 后拷贝这一个文件（WAL 模式，运行中拷贝可能缺最近事务）
    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voca", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voca.sqlite")
    }

    init(url: URL? = nil) throws {
        let dbURL = url ?? Self.defaultURL()
        var config = Configuration()
        // WAL：写事务不长期独占库文件；配合 busy 超时，双实例并发写不再立即 SQLITE_BUSY
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        imageStorage = ClipboardImageStorage(dbQueue: dbQueue)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: Clip.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("note", .text)
                t.column("appName", .text)
                t.column("appBundleID", .text)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_clips_createdAt",
                on: Clip.databaseTableName,
                columns: ["createdAt"]
            )
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "clipboard_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("appName", .text)
                t.column("appBundleID", .text)
                t.column("date", .datetime).notNull()
            }
            try db.create(
                index: "idx_clipboard_date",
                on: "clipboard_entries",
                columns: ["date"]
            )
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN count INTEGER NOT NULL DEFAULT 1")
            // SQLite 限制：ADD COLUMN 不允许 CURRENT_TIMESTAMP 等非常量默认值，用常量后立即回填
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN lastSeenAt DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'")
            try db.execute(sql: "UPDATE clips SET lastSeenAt = createdAt")
            try db.create(table: ClipEvent.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clipId", .integer).notNull()
                    .references(Clip.databaseTableName, onDelete: .cascade)
                t.column("date", .datetime).notNull()
                t.column("appName", .text)
                t.column("appBundleID", .text)
            }
            try db.create(
                index: "idx_clip_events_clipId",
                on: ClipEvent.databaseTableName,
                columns: ["clipId"]
            )
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN url TEXT")
            try db.execute(sql: "ALTER TABLE clip_events ADD COLUMN url TEXT")
            try db.execute(sql: "ALTER TABLE clipboard_entries ADD COLUMN url TEXT")
        }
        migrator.registerMigration("v5") { db in
            // 合并查找预筛键：textHash（可空列，回填后写入路径始终赋值）
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN textHash INTEGER")
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, text FROM clips")
            while let row = try cursor.next() {
                let id: Int64 = row["id"]
                let text: String = row["text"]
                try db.execute(
                    sql: "UPDATE clips SET textHash = ? WHERE id = ?",
                    arguments: [Clip.textHash(of: text), id]
                )
            }
            try db.create(
                index: "idx_clips_textHash",
                on: Clip.databaseTableName,
                columns: ["textHash"]
            )
            // reload/export 的实际排序键；同时移除从未被任何查询使用的 createdAt 索引
            try db.create(
                index: "idx_clips_lastSeenAt",
                on: Clip.databaseTableName,
                columns: ["lastSeenAt"]
            )
            try db.drop(index: "idx_clips_createdAt")
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "clipboard_images") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("data", .blob).notNull()
                t.column("appName", .text)
                t.column("appBundleID", .text)
                t.column("date", .datetime).notNull()
            }
            try db.create(index: "idx_clipboard_images_date", on: "clipboard_images", columns: ["date"])
        }
        try migrator.migrate(dbQueue)
        clips = (try? loadClips(search: "")) ?? []
    }

    // MARK: - 查询

    /// 同步重载（主线程调用）：列表立即一致，供编辑/删除等低频路径使用
    func reload(search: String = "") {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSearch = term
        reloadGeneration += 1
        do {
            clips = try loadClips(search: term)
        } catch {
            Self.logger.error("词库重载失败: \(error, privacy: .public)")
        }
    }

    /// 异步重载（主线程调用）：查询在后台执行，完成后回主线程发布；
    /// 与后续 reload/reloadAsync 竞争时以 generation 丢弃过期结果。
    /// 供搜索击键等高频路径使用，避免主线程同步扫描。
    func reloadAsync(search: String) {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSearch = term
        reloadGeneration += 1
        let generation = reloadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let fetched = try self.loadClips(search: term)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.reloadGeneration == generation else { return }
                    self.clips = fetched
                }
            } catch {
                Self.logger.error("词库搜索重载失败: \(error, privacy: .public)")
            }
        }
    }

    private func loadClips(search term: String) throws -> [Clip] {
        try dbQueue.read { db -> [Clip] in
            if term.isEmpty {
                return try Clip.order(Column("lastSeenAt").desc).limit(2000).fetchAll(db)
            }
            let pattern = Self.likePattern(term)
            return try Clip
                .filter(sql: "text LIKE ? ESCAPE '\\'", arguments: [pattern])
                .order(Column("lastSeenAt").desc)
                .limit(2000)
                .fetchAll(db)
        }
    }

    // MARK: - 写入

    /// 保存（同文本合并去重）：已存在则计数 +1、更新 lastSeenAt 置顶并记录事件；否则新建
    /// url 采用"最新非空值优先"：合并时仅在本次携带 URL 才覆盖
    @discardableResult
    func save(
        text: String,
        appName: String?,
        bundleID: String?,
        url: String? = nil,
        note: String? = nil,
        date: Date = Date()
    ) throws -> Clip {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let hash = Clip.textHash(of: text)
        var result: Clip?
        try dbQueue.write { db in
            if var existing = try Clip
                .filter(Column("textHash") == hash)
                .filter(Column("text") == text)
                .fetchOne(db)
            {
                existing.count += 1
                existing.lastSeenAt = date
                if let url { existing.url = url }
                // 与 URL 同规则：非空备注采用最新值
                if let note, !note.isEmpty { existing.note = note }
                try existing.update(db)
                if let clipId = existing.id {
                    let event = ClipEvent(
                        id: nil,
                        clipId: clipId,
                        date: date,
                        appName: appName,
                        appBundleID: bundleID,
                        url: url
                    )
                    try event.insert(db)
                }
                result = existing
            } else {
                var clip = Clip(
                    id: nil,
                    text: text,
                    note: note,
                    appName: appName,
                    appBundleID: bundleID,
                    wordCount: words.count,
                    createdAt: date,
                    url: url,
                    count: 1,
                    lastSeenAt: date,
                    textHash: hash
                )
                try clip.insert(db)
                if let clipId = clip.id {
                    let event = ClipEvent(
                        id: nil,
                        clipId: clipId,
                        date: date,
                        appName: appName,
                        appBundleID: bundleID,
                        url: url
                    )
                    try event.insert(db)
                }
                result = clip
            }
        }
        guard let saved = result else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: L10n.text("Voca: 保存失败"))
        }
        publishSaved(saved)
        return saved
    }

    /// 保存后的列表发布：高频路径做内存增量（避免每次保存全量重拉 2000 条），
    /// 与 reload 的排序语义一致（最近保存置顶）；搜索过滤激活时退回全量重载保持过滤正确性
    private func publishSaved(_ clip: Clip) {
        if !currentSearch.isEmpty {
            reload(search: currentSearch)
            return
        }
        if let id = clip.id, let index = clips.firstIndex(where: { $0.id == id }) {
            clips[index] = clip
            let moved = clips.remove(at: index)
            clips.insert(moved, at: 0)
        } else {
            clips.insert(clip, at: 0)
            if clips.count > 2000 {
                clips.removeLast(clips.count - 2000)
            }
        }
    }

    /// 某条记录的时间线（每次出现的时间与来源，倒序）
    func events(for clip: Clip) -> [ClipEvent] {
        guard let clipId = clip.id else { return [] }
        return (try? dbQueue.read { db in
            try ClipEvent
                .filter(Column("clipId") == clipId)
                .order(Column("date").desc)
                .fetchAll(db)
        }) ?? []
    }

    /// 导出全部词库为裸条目 Markdown：每条一行，条目间空一行（按最近保存倒序）
    /// 有备注的条目在下一行以 > 引用附注（多行备注每行带 > 前缀）
    func exportMarkdown() -> String {
        let all: [Clip] = (try? dbQueue.read { db in
            try Clip.order(Column("lastSeenAt").desc).fetchAll(db)
        }) ?? []
        let blocks = all.map { clip -> String in
            guard let note = clip.note, !note.isEmpty else {
                return clip.text
            }
            let quoted = note
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            return clip.text + "\n" + quoted
        }
        return blocks.joined(separator: "\n\n")
    }

    func delete(_ clip: Clip) {
        do {
            try dbQueue.write { db in
                if let clipId = clip.id {
                    try db.execute(
                        sql: "DELETE FROM clip_events WHERE clipId = ?",
                        arguments: [clipId]
                    )
                }
                _ = try clip.delete(db)
            }
        } catch {
            Self.logger.error("删除词条失败: \(error, privacy: .public)")
        }
        reload(search: currentSearch)
    }

    /// 编辑已有记录的文本与备注（重算词数，保留来源与创建时间）。
    /// 若新文本与其他记录相同则合并：计数相加、时间线事件转移至既有行、
    /// url/note 取非空优先、lastSeenAt 取较新值，随后删除被编辑的原行。
    func update(_ clip: Clip, text: String, note: String?) {
        var updated = clip
        updated.text = text
        updated.note = note
        updated.wordCount = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        updated.textHash = Clip.textHash(of: text)
        do {
            try dbQueue.write { db in
                var conflictQuery = Clip
                    .filter(Column("textHash") == updated.textHash)
                    .filter(Column("text") == text)
                if let oldId = clip.id {
                    conflictQuery = conflictQuery.filter(Column("id") != oldId)
                }
                if var other = try conflictQuery.fetchOne(db) {
                    other.count += updated.count
                    if other.url == nil { other.url = updated.url }
                    if (other.note ?? "").isEmpty { other.note = updated.note }
                    other.lastSeenAt = max(other.lastSeenAt, updated.lastSeenAt)
                    try other.update(db)
                    if let otherId = other.id, let oldId = clip.id {
                        try db.execute(
                            sql: "UPDATE clip_events SET clipId = ? WHERE clipId = ?",
                            arguments: [otherId, oldId]
                        )
                    }
                    _ = try updated.delete(db)
                } else {
                    try updated.update(db)
                }
            }
        } catch {
            Self.logger.error("编辑词条失败: \(error, privacy: .public)")
        }
        reload(search: currentSearch)
    }

    func deleteAll() {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM clip_events")
                _ = try Clip.deleteAll(db)
            }
        } catch {
            Self.logger.error("清空词库失败: \(error, privacy: .public)")
        }
        reload(search: currentSearch)
    }

    // MARK: - 剪贴板历史持久化

    /// 启动载入最近的历史（新复制内容即时追加，不经过此方法）
    /// limit：载入条数，默认为下方常量
    static let clipboardLoadLimit = 2000

    func loadClipboardEntries(limit: Int = ClipStore.clipboardLoadLimit) -> [ClipboardEntry] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, text, appName, appBundleID, url, date, 0 AS isImage
                    FROM clipboard_entries
                    UNION ALL
                    SELECT id, NULL AS text, appName, appBundleID, NULL AS url, date, 1 AS isImage
                    FROM clipboard_images
                    ORDER BY date DESC LIMIT ?
                    """,
                arguments: [limit]
            )
        }) ?? []
        return rows.compactMap { row in
            let idString: String? = row["id"]
            let text: String? = row["text"]
            guard let id = idString.flatMap(UUID.init(uuidString:)) else { return nil }
            let isImage: Bool = row["isImage"]
            let appName: String? = row["appName"]
            let appBundleID: String? = row["appBundleID"]
            let url: String? = row["url"]
            let date: Date? = row["date"]
            return ClipboardEntry(
                id: id,
                text: text,
                isImage: isImage,
                fileNames: nil,
                appName: appName,
                appBundleID: appBundleID,
                url: url,
                date: date ?? Date()
            )
        }
    }

    /// 直接插入新条目（不去重）；文本历史无上限保留，由用户自行清理
    func saveClipboardEntry(_ entry: ClipboardEntry) {
        guard let text = entry.text else { return }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO clipboard_entries (id, text, appName, appBundleID, url, date) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [entry.id.uuidString, text, entry.appName, entry.appBundleID, entry.url, entry.date]
                )
            }
        } catch {
            Self.logger.error("剪贴板历史写入失败: \(error, privacy: .public)")
        }
    }

    /// URL 异步查询完成后补填既有剪贴板记录
    func updateClipboardEntryURL(id: UUID, url: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE clipboard_entries SET url = ? WHERE id = ?",
                    arguments: [url, id.uuidString]
                )
            }
        } catch {
            Self.logger.error("剪贴板 URL 补填失败: \(error, privacy: .public)")
        }
    }

    func deleteClipboardEntry(id: UUID) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM clipboard_entries WHERE id = ?",
                    arguments: [id.uuidString]
                )
            }
        } catch {
            Self.logger.error("移除剪贴板记录失败: \(error, privacy: .public)")
        }
    }

    func clearClipboardEntries() {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM clipboard_entries")
            }
        } catch {
            Self.logger.error("清空剪贴板历史失败: \(error, privacy: .public)")
        }
    }

    // MARK: - Private

    private static func likePattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}

/// Only GRDB's serialized DatabaseQueue is shared across threads here; no UI state is exposed.
final class ClipboardImageStorage: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private static let logger = Logger(subsystem: "local.voca.Voca", category: "clipboard-images")

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    @discardableResult
    func saveClipboardImage(_ entry: ClipboardEntry, type: String, data: Data) -> Bool {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO clipboard_images (id, type, data, appName, appBundleID, date) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [entry.id.uuidString, type, data, entry.appName, entry.appBundleID, entry.date]
                )
            }
            return true
        } catch {
            Self.logger.error("图片历史写入失败: \(error, privacy: .public)")
            return false
        }
    }

    func loadClipboardImage(id: UUID) -> (type: String, data: Data)? {
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT type, data FROM clipboard_images WHERE id = ?", arguments: [id.uuidString]
                ) else { return nil }
                return (row["type"], row["data"])
            }
        } catch {
            Self.logger.error("图片历史读取失败: \(error, privacy: .public)")
            return nil
        }
    }

    func deleteClipboardImage(id: UUID) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM clipboard_images WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            Self.logger.error("移除图片记录失败: \(error, privacy: .public)")
        }
    }

    func clearClipboardImages() {
        do {
            try dbQueue.write { db in try db.execute(sql: "DELETE FROM clipboard_images") }
        } catch {
            Self.logger.error("清空图片历史失败: \(error, privacy: .public)")
        }
    }
}
