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

import Foundation
import GRDB

/// 设置页的数据信息与备份：独立只读/短写连接访问词库数据库，
/// 不经过（也不改动）ClipStore，避免与主库写路径耦合。
enum LibraryInfo {
    struct Stats: Equatable {
        var clips = 0
        var saves = 0
        var events = 0
        var clipboardEntries = 0
    }

    /// 词库统计（后台线程调用；用户库表规模小，查询毫秒级）
    static func stats(databaseURL: URL) -> Stats {
        var result = Stats()
        let dbQueue = try? DatabaseQueue(path: databaseURL.path)
        _ = try? dbQueue?.read { db in
            result.clips = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM clips") ?? 0
            result.saves = try Int.fetchOne(
                db, sql: "SELECT IFNULL(SUM(count), 0) FROM clips") ?? 0
            result.events = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM clip_events") ?? 0
            result.clipboardEntries = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM clipboard_entries") ?? 0
        }
        return result
    }

    /// 数据库占用字节数（主文件 + WAL + SHM）
    static func databaseBytes(databaseURL: URL) -> Int64 {
        let candidates = [
            databaseURL.path,
            databaseURL.path + "-wal",
            databaseURL.path + "-shm",
        ]
        var total: Int64 = 0
        for path in candidates {
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// 运行中安全备份：VACUUM INTO 生成紧凑快照（自动包含最近事务），
    /// 目标已存在时先删除（VACUUM INTO 不允许覆盖已有文件）。
    static func backup(databaseURL: URL, to destination: URL) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // VACUUM 不能在事务内执行，inDatabase 不包事务
        try dbQueue.inDatabase { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
        }
    }

    /// 字节数的易读格式
    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
