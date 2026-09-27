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
