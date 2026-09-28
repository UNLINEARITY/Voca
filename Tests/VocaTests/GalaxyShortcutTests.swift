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
import KeyboardShortcuts
import XCTest
@testable import Voca

@MainActor
final class GalaxyShortcutTests: XCTestCase {
    private func keyEvent(
        _ key: KeyboardShortcuts.Key, type: NSEvent.EventType = .keyDown,
        repeating: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [.option, .shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: repeating, keyCode: UInt16(key.rawValue)
        )!
    }

    func testDefaultShortcutOnlyMatchesFocusedGalaxy() {
        let shortcut = KeyboardShortcuts.Name.galaxyTuning.defaultShortcut
        XCTAssertEqual(shortcut, KeyboardShortcuts.Shortcut(.g, modifiers: [.option, .shift]))
        GalaxyWindowController.keepTuningShortcutLocal()
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: .galaxyTuning))
        XCTAssertTrue(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g), galaxyIsFocused: true, shortcut: shortcut
        ))
        XCTAssertFalse(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g), galaxyIsFocused: false, shortcut: shortcut
        ))
        XCTAssertFalse(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g, repeating: true), galaxyIsFocused: true, shortcut: shortcut
        ))
        XCTAssertFalse(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g, type: .keyUp), galaxyIsFocused: true, shortcut: shortcut
        ))
    }

    func testShortcutLibraryRegistersNewDefaultsAndRecorderChangesGlobally() {
        let name = KeyboardShortcuts.Name(
            "galaxyTuningTest_\(UUID().uuidString)",
            default: .init(.f, modifiers: [.option, .shift])
        )
        defer {
            KeyboardShortcuts.disable(name)
            UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(name.rawValue)")
        }

        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))
        KeyboardShortcuts.disable(name)
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), name.defaultShortcut)

        KeyboardShortcuts.setShortcut(.init(.h, modifiers: [.option, .shift]), for: name)
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))
        KeyboardShortcuts.disable(name)
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), .init(.h, modifiers: [.option, .shift]))
    }

    func testCustomGalaxyShortcutRemainsLocalAfterRecording() {
        let previous = KeyboardShortcuts.getShortcut(for: .galaxyTuning)
        defer {
            KeyboardShortcuts.setShortcut(previous, for: .galaxyTuning)
            GalaxyWindowController.keepTuningShortcutLocal()
        }

        let custom = KeyboardShortcuts.Shortcut(.h, modifiers: [.option, .shift])
        KeyboardShortcuts.setShortcut(custom, for: .galaxyTuning)
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: .galaxyTuning))
        GalaxyWindowController.keepTuningShortcutLocal()
        XCTAssertFalse(KeyboardShortcuts.isEnabled(for: .galaxyTuning))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: .galaxyTuning), custom)
    }

    func testSphereFontSizeScalesWithSaveCount() {
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 1), 25)
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 2), 27.5)
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 5), 35)
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 9), 45)
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 100), 45)
        XCTAssertEqual(GalaxyModel.sphereFontSize(count: 0), 25)
    }

    /// 帮助页快捷键目录是单一来源：新增 KeyboardShortcuts.Name 而未登记进
    /// HelpShortcutCatalog 时，此测试失败，确保帮助页自动覆盖全部快捷键。
    func testEveryCustomizableShortcutIsCataloguedForHelp() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Voca")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let declaration = try NSRegularExpression(pattern: #"static\s+let\s+(\w+)\s*=\s*Self\(\"(\w+)\""#)
        var declared: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("extension KeyboardShortcuts.Name") else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in declaration.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 2), in: source) else { continue }
                declared.insert(String(source[nameRange]))
            }
        }
        let catalogued = Set(HelpShortcutCatalog.customizable.map(\.name.rawValue))
        XCTAssertEqual(
            declared.subtracting(catalogued), [],
            "新增 KeyboardShortcuts.Name 必须登记进 HelpShortcutCatalog，帮助页才会自动列出它"
        )
        XCTAssertFalse(HelpShortcutCatalog.fixed.isEmpty)
        XCTAssertEqual(HelpShortcutCatalog.customizable.map(\.name.rawValue).count, catalogued.count,
                       "帮助页目录中的可自定义快捷键不得重复")
    }

    func testCustomShortcutAndClearingAreRespected() {
        let custom = KeyboardShortcuts.Shortcut(.h, modifiers: [.option, .shift])
        XCTAssertTrue(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.h), galaxyIsFocused: true, shortcut: custom
        ))
        XCTAssertFalse(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g), galaxyIsFocused: true, shortcut: custom
        ))
        XCTAssertFalse(GalaxyWindowController.shouldToggleTuning(
            for: keyEvent(.g), galaxyIsFocused: true, shortcut: nil
        ))
    }
}
