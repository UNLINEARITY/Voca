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

/// Pure, per-device recognizer. Coordinates are physical millimetres, with positive Y down.
struct ThreeFingerSwipeRecognizer {
    struct Frame {
        let time: TimeInterval
        let contactCount: Int
        let x: Double
        let y: Double
    }

    private enum Phase {
        case idle
        case tracking(start: Frame, last: Frame, confirmedAt: TimeInterval?, downDistance: Double, maximumSide: Double, sawPartialLift: Bool)
        case rejected
    }

    private var phase: Phase = .idle
    private var lastFire: TimeInterval = -.infinity

    mutating func reset() { phase = .idle }

    /// Returns true only on complete release, never during the moving gesture.
    mutating func consume(_ frame: Frame) -> Bool {
        if frame.contactCount >= 4 {
            phase = .rejected
            return false
        }
        if frame.contactCount == 0 {
            defer { phase = .idle }
            guard case let .tracking(start, last, confirmedAt, downDistance, maximumSide, _) = phase,
                  confirmedAt != nil,
                  frame.time - last.time < 0.25,
                  frame.time - start.time <= 1.2,
                  frame.time - lastFire >= 0.6,
                  downDistance >= 12,
                  maximumSide <= downDistance * 0.65 else { return false }
            lastFire = frame.time
            return true
        }
        switch phase {
        case .idle:
            if frame.contactCount == 3 {
                phase = .tracking(start: frame, last: frame, confirmedAt: nil,
                                  downDistance: 0, maximumSide: 0, sawPartialLift: false)
            }
        case let .tracking(start, last, confirmedAt, downDistance, maximumSide, sawPartialLift):
            guard frame.time >= last.time, frame.time - last.time < 0.25,
                  frame.time - start.time <= 1.2 else {
                phase = .rejected
                return false
            }
            if frame.contactCount == 3 {
                guard !sawPartialLift else { phase = .rejected; return false }
                let down = frame.y - start.y
                let side = abs(frame.x - start.x)
                if down < -4 || side > max(10, down * 0.85) {
                    phase = .rejected
                } else {
                    phase = .tracking(start: start, last: frame,
                                      confirmedAt: confirmedAt ?? (frame.time - start.time >= 0.04 ? frame.time : nil),
                                      downDistance: down,
                                      maximumSide: max(maximumSide, side), sawPartialLift: false)
                }
            } else {
                // Fingers can lift a few milliseconds apart; do not start a new gesture.
                phase = .tracking(start: start, last: frame, confirmedAt: confirmedAt,
                                  downDistance: downDistance, maximumSide: maximumSide,
                                  sawPartialLift: true)
            }
        case .rejected:
            break
        }
        return false
    }
}
