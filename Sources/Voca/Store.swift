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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
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
        try migrator.migrate(dbQueue)
        reload()
    }

    // MARK: - 查询

    func reload(search: String = "") {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            clips = try dbQueue.read { db -> [Clip] in
                if term.isEmpty {
                    return try Clip.order(Column("createdAt").desc).limit(2000).fetchAll(db)
                }
                let pattern = Self.likePattern(term)
                return try Clip
                    .filter(sql: "text LIKE ? ESCAPE '\\'", arguments: [pattern])
                    .order(Column("createdAt").desc)
                    .limit(2000)
                    .fetchAll(db)
            }
        } catch {
            NSLog("Voca reload error: %@", "\(error)")
        }
    }

    /// 3 秒内同文本 + 同来源视为重复，不再入库
    func isRecentDuplicate(text: String, bundleID: String?) -> Bool {
        let cutoff = Date().addingTimeInterval(-3)
        var sql = "text = ? AND createdAt > ?"
        var args: [DatabaseValueConvertible] = [text, cutoff]
        if let bundleID {
            sql += " AND appBundleID = ?"
            args.append(bundleID)
        }
        let count = (try? dbQueue.read { db in
            try Clip.filter(sql: sql, arguments: StatementArguments(args)).fetchCount(db)
        }) ?? 0
        return count > 0
    }

    // MARK: - 写入

    @discardableResult
    func insert(
        text: String,
        appName: String?,
        bundleID: String?,
        date: Date = Date()
    ) throws -> Clip {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var clip = Clip(
            id: nil,
            text: text,
            note: nil,
            appName: appName,
            appBundleID: bundleID,
            wordCount: words.count,
            createdAt: date
        )
        try dbQueue.write { db in
            try clip.insert(db)
        }
        reload()
        return clip
    }

    func delete(_ clip: Clip) {
        try? dbQueue.write { db in
            _ = try clip.delete(db)
        }
        reload()
    }

    func deleteAll() {
        try? dbQueue.write { db in
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
