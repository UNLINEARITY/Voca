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
import XCTest
@testable import Voca

@MainActor
final class ClipboardImageTests: XCTestCase {
    func testImageWinsOverAccompanyingText() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("VocaTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        item.setString("image description", forType: .string)
        item.setData(data, forType: .tiff)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(board.string(forType: .string), "image description")
        let representation = try XCTUnwrap(ClipboardWatcher.imageRepresentation(on: board))
        XCTAssertEqual(representation.type, .tiff)
        XCTAssertEqual(representation.data, data)
    }

    func testImagePersistsAndCanBeCopiedAfterReopeningDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voca.sqlite")
        let id = UUID()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let entry = ClipboardEntry(
            id: id, text: nil, isImage: true, fileNames: nil,
            appName: "Test", appBundleID: nil, url: nil, date: Date()
        )
        do {
            let store = try ClipStore(url: url)
            XCTAssertTrue(store.imageStorage.saveClipboardImage(entry, type: NSPasteboard.PasteboardType.tiff.rawValue, data: data))
        }
        let reopened = try ClipStore(url: url)
        XCTAssertTrue(reopened.loadClipboardEntries().contains { $0.id == id && $0.isImage })
        let restored = try XCTUnwrap(reopened.imageStorage.loadClipboardImage(id: id))
        XCTAssertEqual(restored.type, NSPasteboard.PasteboardType.tiff.rawValue)
        XCTAssertEqual(restored.data, data)

        let board = NSPasteboard(name: NSPasteboard.Name("VocaTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(ClipboardWatcher.writeImage(type: .init(restored.type), data: restored.data, on: board))
        XCTAssertEqual(board.data(forType: .tiff), data)
        XCTAssertNotNil(NSImage(pasteboard: board))

        reopened.imageStorage.clearClipboardImages()
        XCTAssertNil(reopened.imageStorage.loadClipboardImage(id: id))
        XCTAssertFalse(reopened.loadClipboardEntries().contains { $0.id == id })
    }
}
