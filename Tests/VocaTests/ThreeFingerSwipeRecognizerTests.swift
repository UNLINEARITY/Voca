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

import XCTest
@testable import Voca

final class ThreeFingerSwipeRecognizerTests: XCTestCase {
    private typealias Frame = ThreeFingerSwipeRecognizer.Frame

    private func frame(_ time: Double, _ count: Int, _ x: Double = 50, _ y: Double = 30) -> Frame {
        Frame(time: time, contactCount: count, x: x, y: y)
    }

    func testDownwardSwipeFiresOnlyAtRelease() {
        var recognizer = ThreeFingerSwipeRecognizer()
        XCTAssertFalse(recognizer.consume(frame(0, 3)))
        XCTAssertFalse(recognizer.consume(frame(0.06, 3, 51, 37)))
        XCTAssertFalse(recognizer.consume(frame(0.12, 3, 52, 45)))
        XCTAssertTrue(recognizer.consume(frame(0.16, 0)))
        XCTAssertFalse(recognizer.consume(frame(0.17, 0)))
    }

    func testUpwardAndHorizontalSwipesDoNotFire() {
        for destination in [(50.0, 15.0), (70.0, 32.0), (65.0, 44.0)] {
            var recognizer = ThreeFingerSwipeRecognizer()
            _ = recognizer.consume(frame(0, 3))
            _ = recognizer.consume(frame(0.08, 3, destination.0, destination.1))
            XCTAssertFalse(recognizer.consume(frame(0.13, 0)))
        }
    }

    func testFourFingerTailAndLateFourthFingerAreRejected() {
        var recognizer = ThreeFingerSwipeRecognizer()
        _ = recognizer.consume(frame(0, 4))
        _ = recognizer.consume(frame(0.06, 3, 50, 38))
        _ = recognizer.consume(frame(0.12, 3, 50, 47))
        XCTAssertFalse(recognizer.consume(frame(0.16, 0)))

        _ = recognizer.consume(frame(1, 3))
        _ = recognizer.consume(frame(1.06, 3, 50, 38))
        _ = recognizer.consume(frame(1.08, 4, 50, 39))
        _ = recognizer.consume(frame(1.12, 3, 50, 47))
        XCTAssertFalse(recognizer.consume(frame(1.16, 0)))
    }

    func testStallAndShortSwipeAreRejected() {
        var recognizer = ThreeFingerSwipeRecognizer()
        _ = recognizer.consume(frame(0, 3))
        _ = recognizer.consume(frame(0.06, 3, 50, 37))
        XCTAssertFalse(recognizer.consume(frame(0.11, 0)))

        _ = recognizer.consume(frame(1, 3))
        _ = recognizer.consume(frame(1.4, 3, 50, 48))
        XCTAssertFalse(recognizer.consume(frame(1.43, 0)))
    }

    func testContactDropoutCannotRearmSameSwipe() {
        var recognizer = ThreeFingerSwipeRecognizer()
        _ = recognizer.consume(frame(0, 3))
        _ = recognizer.consume(frame(0.06, 3, 50, 38))
        _ = recognizer.consume(frame(0.08, 2, 50, 38))
        _ = recognizer.consume(frame(0.10, 3, 50, 47))
        XCTAssertFalse(recognizer.consume(frame(0.14, 0)))
    }

    func testStaggeredLiftAndDuplicateGuard() {
        var recognizer = ThreeFingerSwipeRecognizer()
        _ = recognizer.consume(frame(0, 3))
        _ = recognizer.consume(frame(0.06, 3, 50, 38))
        _ = recognizer.consume(frame(0.12, 3, 50, 45))
        _ = recognizer.consume(frame(0.13, 2, 50, 45))
        XCTAssertTrue(recognizer.consume(frame(0.15, 0)))

        _ = recognizer.consume(frame(0.2, 3))
        _ = recognizer.consume(frame(0.27, 3, 50, 45))
        XCTAssertFalse(recognizer.consume(frame(0.3, 0)))

        _ = recognizer.consume(frame(1, 3))
        _ = recognizer.consume(frame(1.08, 3, 50, 45))
        XCTAssertTrue(recognizer.consume(frame(1.12, 0)))
    }
}
