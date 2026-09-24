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

final class CaptureEngineTests: XCTestCase {
    private func temporaryPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("VocaTests.\(UUID().uuidString)"))
    }

    func testUnchangedCopyReleasesWatcherSuppression() {
        let board = temporaryPasteboard()
        defer { board.releaseGlobally() }

        XCTAssertNil(CaptureEngine.shared.copyFallback(on: board, postCopy: {}))
        XCTAssertFalse(CaptureEngine.isSimulatingCopy)
        XCTAssertTrue(CaptureEngine.beginSimulatedCopy())
        CaptureEngine.endSimulatedCopy()
    }

    func testNonTextCopyRestoresPreviousPasteboard() {
        let board = temporaryPasteboard()
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("previous", forType: .string))

        XCTAssertNil(CaptureEngine.shared.copyFallback(on: board) {
            board.clearContents()
            board.setData(Data([1]), forType: NSPasteboard.PasteboardType("voca.test.binary"))
        })
        waitForRestoration()
        XCTAssertEqual(board.string(forType: .string), "previous")
        XCTAssertFalse(CaptureEngine.isSimulatingCopy)
    }

    func testNewUserCopyIsNotOverwrittenDuringRestoration() {
        let board = temporaryPasteboard()
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("previous", forType: .string))

        XCTAssertEqual(CaptureEngine.shared.copyFallback(on: board) {
            board.clearContents()
            board.setString("simulated", forType: .string)
        }, "simulated")
        board.clearContents()
        XCTAssertTrue(board.setString("user copy", forType: .string))
        waitForRestoration()
        XCTAssertEqual(board.string(forType: .string), "user copy")
        XCTAssertFalse(CaptureEngine.isSimulatingCopy)
    }

    private func waitForRestoration() {
        let done = expectation(description: "pasteboard restoration")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 1)
    }
}
