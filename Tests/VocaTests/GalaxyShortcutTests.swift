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
