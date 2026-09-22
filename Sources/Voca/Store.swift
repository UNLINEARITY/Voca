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
    /// 同文本出现次数（去重合并）
    var count: Int
    /// 最近一次保存时间（列表置顶排序键）
    var lastSeenAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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
}

final class ClipStore: ObservableObject {
    private let dbQueue: DatabaseQueue
    @Published private(set) var clips: [Clip] = []

    /// 数据库位置：~/Library/Application Support/Voca/voca.sqlite（备份 = 拷贝这一个文件）
    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voca", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voca.sqlite")
    }

    init(url: URL? = nil) throws {
        let dbURL = url ?? Self.defaultURL()
        dbQueue = try DatabaseQueue(path: dbURL.path)

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
        try migrator.migrate(dbQueue)
        reload()
    }

    // MARK: - 查询

    func reload(search: String = "") {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            clips = try dbQueue.read { db -> [Clip] in
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
        } catch {
            NSLog("Voca reload error: %@", "\(error)")
        }
    }

    // MARK: - 写入

    /// 保存（同文本合并去重）：已存在则计数 +1、更新 lastSeenAt 置顶并记录事件；否则新建
    @discardableResult
    func save(
        text: String,
        appName: String?,
        bundleID: String?,
        date: Date = Date()
    ) throws -> Clip {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var result: Clip?
        try dbQueue.write { db in
            if var existing = try Clip.filter(Column("text") == text).fetchOne(db) {
                existing.count += 1
                existing.lastSeenAt = date
                try existing.update(db)
                if let clipId = existing.id {
                    let event = ClipEvent(
                        id: nil,
                        clipId: clipId,
                        date: date,
                        appName: appName,
                        appBundleID: bundleID
                    )
                    try event.insert(db)
                }
                result = existing
            } else {
                var clip = Clip(
                    id: nil,
                    text: text,
                    note: nil,
                    appName: appName,
                    appBundleID: bundleID,
                    wordCount: words.count,
                    createdAt: date,
                    count: 1,
                    lastSeenAt: date
                )
                try clip.insert(db)
                if let clipId = clip.id {
                    let event = ClipEvent(
                        id: nil,
                        clipId: clipId,
                        date: date,
                        appName: appName,
                        appBundleID: bundleID
                    )
                    try event.insert(db)
                }
                result = clip
            }
        }
        reload()
        guard let saved = result else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Voca: 保存失败")
        }
        return saved
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
        try? dbQueue.write { db in
            if let clipId = clip.id {
                try db.execute(
                    sql: "DELETE FROM clip_events WHERE clipId = ?",
                    arguments: [clipId]
                )
            }
            _ = try clip.delete(db)
        }
        reload()
    }

    /// 编辑已有记录的文本与备注（重算词数，保留来源与创建时间）
    func update(_ clip: Clip, text: String, note: String?) {
        var updated = clip
        updated.text = text
        updated.note = note
        updated.wordCount = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
        try? dbQueue.write { db in
            try updated.update(db)
        }
        reload()
    }

    func deleteAll() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clip_events")
            _ = try Clip.deleteAll(db)
        }
        reload()
    }

    // MARK: - 剪贴板历史持久化（仅文本条目）

    func loadClipboardEntries() -> [ClipboardEntry] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, text, appName, appBundleID, date FROM clipboard_entries ORDER BY date DESC LIMIT 200"
            )
        }) ?? []
        return rows.compactMap { row in
            let idString: String? = row["id"]
            let text: String? = row["text"]
            guard let id = idString.flatMap(UUID.init(uuidString:)), let text else {
                return nil
            }
            let appName: String? = row["appName"]
            let appBundleID: String? = row["appBundleID"]
            let date: Date? = row["date"]
            return ClipboardEntry(
                id: id,
                text: text,
                image: nil,
                fileNames: nil,
                appName: appName,
                appBundleID: appBundleID,
                date: date ?? Date()
            )
        }
    }

    /// 直接插入新条目（不去重），并维持最多 200 条
    func saveClipboardEntry(_ entry: ClipboardEntry) {
        guard let text = entry.text else { return }
        try? dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO clipboard_entries (id, text, appName, appBundleID, date) VALUES (?, ?, ?, ?, ?)",
                arguments: [entry.id.uuidString, text, entry.appName, entry.appBundleID, entry.date]
            )
            try db.execute(
                sql: "DELETE FROM clipboard_entries WHERE id NOT IN (SELECT id FROM clipboard_entries ORDER BY date DESC LIMIT 200)"
            )
        }
    }

    func deleteClipboardEntry(id: UUID) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM clipboard_entries WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func clearClipboardEntries() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clipboard_entries")
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
