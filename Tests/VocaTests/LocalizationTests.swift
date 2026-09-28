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
import KeyboardShortcuts
import XCTest
@testable import Voca

final class LocalizationTests: XCTestCase {
    func testPreferenceOverridesAndRestoresSystemLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: DisplayLanguage.preferenceKey)
        defer { defaults.set(previous, forKey: DisplayLanguage.preferenceKey) }

        defaults.set(DisplayLanguage.english.rawValue, forKey: DisplayLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("词库"), "Library")
        XCTAssertEqual(L10n.format("%d 条", 2), "2 items")

        defaults.set(DisplayLanguage.simplifiedChinese.rawValue, forKey: DisplayLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("词库"), "词库")
        XCTAssertEqual(L10n.format("%d 条", 2), "2 条")

        defaults.set(DisplayLanguage.system.rawValue, forKey: DisplayLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("词库"), L10n.resourceBundle.localizedString(forKey: "词库", value: "词库", table: nil))
    }

    @MainActor
    func testHelpUsesCurrentBindingsInBothLanguages() {
        let previous = KeyboardShortcuts.getShortcut(for: .galaxyTuning)
        defer {
            KeyboardShortcuts.setShortcut(previous, for: .galaxyTuning)
            GalaxyWindowController.keepTuningShortcutLocal()
        }
        let custom = KeyboardShortcuts.Shortcut(.h, modifiers: [.option, .shift])
        KeyboardShortcuts.setShortcut(custom, for: .galaxyTuning)
        GalaxyWindowController.keepTuningShortcutLocal()

        XCTAssertEqual(
            HelpContentView.shortcutLine("星图设置（仅星图聚焦时）：", name: .galaxyTuning, language: .english),
            "Galaxy settings (galaxy focused): " + custom.description
        )
        XCTAssertEqual(
            HelpContentView.shortcutLine("星图设置（仅星图聚焦时）：", name: .galaxyTuning, language: .simplifiedChinese),
            "星图设置（仅星图聚焦时）：" + custom.description
        )
        KeyboardShortcuts.setShortcut(nil, for: .galaxyTuning)
        XCTAssertEqual(
            HelpContentView.shortcutLine("星图设置（仅星图聚焦时）：", name: .galaxyTuning, language: .english),
            "Galaxy settings (galaxy focused): Not set"
        )
    }

    @MainActor
    func testNativeMenuLanguageRestoresPerAppOverride() throws {
        let domain = "VocaNativeMenuLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["fr"], forKey: "AppleLanguages")

        XCTAssertTrue(NativeMenuLanguagePreference.apply(.english, defaults: defaults, domain: domain))
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["en"])
        XCTAssertTrue(NativeMenuLanguagePreference.apply(.simplifiedChinese, defaults: defaults, domain: domain))
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["zh-Hans"])
        XCTAssertTrue(NativeMenuLanguagePreference.apply(.system, defaults: defaults, domain: domain))
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String], ["fr"])
        XCTAssertFalse(NativeMenuLanguagePreference.apply(.system, defaults: defaults, domain: domain))

        defaults.removeObject(forKey: "AppleLanguages")
        XCTAssertTrue(NativeMenuLanguagePreference.apply(.english, defaults: defaults, domain: domain))
        XCTAssertTrue(NativeMenuLanguagePreference.apply(.system, defaults: defaults, domain: domain))
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }

    func testAppResourcesResolvesModuleBundleToolchainIndependently() {
        XCTAssertNotNil(
            AppResources.module.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj")
        )
        XCTAssertNotNil(AppResources.module.url(forResource: "terms", withExtension: "sqlite"))
    }

    func testChineseSourceLiteralsHaveEnglishTranslations() throws {
        let bundle = L10n.resourceBundle
        let stringsPath = try XCTUnwrap(bundle.path(
            forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj"
        ))
        let translations = try XCTUnwrap(NSDictionary(contentsOfFile: stringsPath) as? [String: String])
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Voca")
        let pattern = try NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)""#)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Diagnostic logs are not user-facing; interpolated strings use formatting APIs.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("*"),
                      !line.contains("NSLog(") else { continue }
                let text = String(line)
                let range = NSRange(text.startIndex..., in: text)
                for match in pattern.matches(in: text, range: range) {
                    guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
                    let literal = String(text[valueRange])
                    guard literal.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
                          !literal.contains(#"\("#) else { continue }
                    let key = literal.replacingOccurrences(of: #"\n"#, with: "\n")
                    XCTAssertNotNil(translations[key], "\(file.lastPathComponent):\(index + 1): \(literal)")
                }
            }
        }
    }

    func testBothLanguagesCoverSameKeysAndFormats() throws {
        let bundle = L10n.resourceBundle
        func strings(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: "\(language).lproj"))
            return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        }
        let en = try strings("en")
        let zh = try strings("zh-Hans")
        XCTAssertEqual(Set(en.keys), Set(zh.keys))
        XCTAssertEqual(en["词库"], "Library")
        XCTAssertEqual(L10n.text("星图", language: .english), "Galaxy")
        XCTAssertEqual(L10n.text("打开时间线星图", language: .english), "Open Timeline Galaxy")
        XCTAssertEqual(L10n.text("Voca 帮助", language: .english), "Voca Help")
        for value in en.values {
            XCTAssertFalse(value.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
                           "Untranslated English text: \(value)")
        }
        XCTAssertEqual(zh["词库"], "词库")
        XCTAssertEqual(L10n.text("词库", language: .english), "Library")
        XCTAssertEqual(L10n.text("词库", language: .simplifiedChinese), "词库")
        XCTAssertEqual(DisplayLanguage(rawValue: "unrecognized") ?? .system, .system)
        XCTAssertEqual(en["已入库（第 %d 次）"], "Saved to library (%d times)")
        XCTAssertTrue(["2 items", "2 条"].contains(L10n.format("%d 条", 2)))
        for key in en.keys {
            let placeholders = try NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:@|d)")
            func specs(_ string: String) -> [String] {
                let range = NSRange(string.startIndex..., in: string)
                return placeholders.matches(in: string, range: range).compactMap { Range($0.range, in: string).map { String(string[$0]) } }
            }
            XCTAssertEqual(specs(en[key]!), specs(zh[key]!), "Format arguments differ for \(key)")
        }
    }
}
