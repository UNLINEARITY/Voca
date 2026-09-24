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
import CoreFoundation
import Darwin
import Foundation

// Private, undocumented macOS ABI. Loaded only when the user opts in; failure is harmless.
private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, Double, Int) -> Void
private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback) -> Void
private typealias UnregisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback?) -> Void
private typealias SurfaceDimensions = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsRunning = @convention(c) (UnsafeMutableRawPointer?) -> Bool
private typealias CreateDefault = @convention(c) () -> UnsafeMutableRawPointer?

private struct MTPoint { var x: Float; var y: Float }
private struct MTVector { var position: MTPoint; var velocity: MTPoint }
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private struct MultitouchAPI {
    let handle: UnsafeMutableRawPointer
    let createList: CreateList
    let start: StartDevice
    let stop: StopDevice
    let register: RegisterCallback
    let unregister: UnregisterCallback
    let dimensions: SurfaceDimensions
    let deviceID: DeviceID
    let isRunning: IsRunning
    let createDefault: CreateDefault

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: type)
        }
        guard let createList = symbol("MTDeviceCreateList", as: CreateList.self),
              let start = symbol("MTDeviceStart", as: StartDevice.self),
              let stop = symbol("MTDeviceStop", as: StopDevice.self),
              let register = symbol("MTRegisterContactFrameCallback", as: RegisterCallback.self),
              let unregister = symbol("MTUnregisterContactFrameCallback", as: UnregisterCallback.self),
              let dimensions = symbol("MTDeviceGetSensorSurfaceDimensions", as: SurfaceDimensions.self),
              let deviceID = symbol("MTDeviceGetDeviceID", as: DeviceID.self),
              let isRunning = symbol("MTDeviceIsRunning", as: IsRunning.self),
              let createDefault = symbol("MTDeviceCreateDefault", as: CreateDefault.self) else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.createList = createList
        self.start = start
        self.stop = stop
        self.register = register
        self.unregister = unregister
        self.dimensions = dimensions
        self.deviceID = deviceID
        self.isRunning = isRunning
        self.createDefault = createDefault
    }
}

/// The framework calls back on its own thread. Its touch buffer is copied before returning.
final class TrackpadGestureMonitor {
    static let shared = TrackpadGestureMonitor()

    enum Status: Equatable {
        case off, unavailable, waiting, ready
    }

    var onStatus: ((Status) -> Void)?
    var onSave: (() -> Void)?

    private struct Device {
        let pointer: UnsafeMutableRawPointer
        let hardwareID: UInt64?
        let widthMM: Double
        let heightMM: Double
        var recognizer = ThreeFingerSwipeRecognizer()
    }

    private let queue = DispatchQueue(label: "local.voca.Voca.trackpad", qos: .userInteractive)
    private var api: MultitouchAPI?
    private var devices: [UInt: Device] = [:]
    // Private device wrappers have shown over-release on disconnect. Retain only lists that
    // introduced devices until process exit; unchanged polling lists are released immediately.
    private var deviceOwners: [CFArray] = []
    private var timer: DispatchSourceTimer?
    private var enabled = false
    private var generation = 0
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    func setEnabled(_ value: Bool) {
        queue.async { [self] in
            guard self.enabled != value else { return }
            self.enabled = value
            self.generation += 1
            if value {
                if self.api == nil { self.api = MultitouchAPI() }
                guard self.api != nil else {
                    self.publish(.unavailable)
                    return
                }
                self.reconcile()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 3, repeating: 3)
                timer.setEventHandler { [weak self] in self?.reconcile() }
                self.timer = timer
                timer.resume()
                DispatchQueue.main.async {
                    self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                    ) { [weak self] _ in self?.refreshAfterWake() }
                }
            } else {
                self.timer?.cancel()
                self.timer = nil
                self.stopAll()
                self.publish(.off)
                DispatchQueue.main.async {
                    if let observer = self.wakeObserver {
                        NSWorkspace.shared.notificationCenter.removeObserver(observer)
                        self.wakeObserver = nil
                    }
                }
            }
        }
    }

    private func refreshAfterWake() {
        queue.async {
            guard self.enabled else { return }
            self.stopAll()
            self.reconcile()
        }
    }

    private func hardwareID(of pointer: UnsafeMutableRawPointer, api: MultitouchAPI) -> UInt64? {
        var id: UInt64 = 0
        return api.deviceID(pointer, &id) == 0 && id != 0 ? id : nil
    }

    private func reconcile() {
        guard enabled, let api, let list = api.createList()?.takeRetainedValue() else {
            if enabled { publish(.waiting) }
            return
        }
        var seen = Set<UInt64>()
        var seenPointers = Set<UInt>()
        var introduced = false
        var candidates: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            if let pointer = CFArrayGetValueAtIndex(list, index) {
                candidates.append(UnsafeMutableRawPointer(mutating: pointer))
            }
        }
        if candidates.isEmpty, let fallback = api.createDefault() { candidates.append(fallback) }
        for device in candidates {
            let key = UInt(bitPattern: device)
            let id = hardwareID(of: device, api: api)
            if let id { seen.insert(id) }
            seenPointers.insert(key)
            if let existing = devices.first(where: { id != nil ? $0.value.hardwareID == id : $0.key == key }) {
                if api.isRunning(existing.value.pointer) { continue }
                api.unregister(existing.value.pointer, Self.callback)
                _ = api.stop(existing.value.pointer)
                devices.removeValue(forKey: existing.key)
            }
            var width: Int32 = 0
            var height: Int32 = 0
            let dimensionStatus = api.dimensions(device, &width, &height)
            if dimensionStatus != 0 || width <= 0 || height <= 0 { width = 16_000; height = 11_500 }
            api.register(device, Self.callback)
            if api.start(device, 0) == 0 {
                devices[key] = Device(pointer: device, hardwareID: id, widthMM: Double(width) / 100,
                                      heightMM: Double(height) / 100)
                introduced = true
            } else {
                api.unregister(device, Self.callback)
            }
        }
        if introduced { deviceOwners.append(list) }
        for key in devices.keys.filter({ key in
            guard let device = devices[key] else { return false }
            return device.hardwareID.map { !seen.contains($0) } ?? !seenPointers.contains(key)
        }) {
            if let device = devices.removeValue(forKey: key) {
                api.unregister(device.pointer, Self.callback)
                _ = api.stop(device.pointer)
            }
        }
        publish(devices.isEmpty ? .waiting : .ready)
    }

    private func stopAll() {
        if let api {
            for device in devices.values {
                api.unregister(device.pointer, Self.callback)
                _ = api.stop(device.pointer)
            }
        }
        devices.removeAll()
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private static let callback: ContactCallback = { device, touches, count, timestamp, _ in
        guard let device, count >= 0, count <= 16, timestamp.isFinite else { return }
        guard count == 0 || touches != nil else { return }
        let raw = touches?.assumingMemoryBound(to: MTTouch.self)
        var active = 0
        var x = 0.0
        var y = 0.0
        if let raw {
            for index in 0..<count {
                let touch = raw[index]
                guard (3...4).contains(touch.state) else { continue }
                let position = touch.normalizedVector.position
                guard position.x.isFinite, position.y.isFinite,
                      (0...1).contains(position.x), (0...1).contains(position.y) else {
                    active = 4
                    break
                }
                // Oversized contact: reject the whole gesture, rather than treating
                // a palm as one of the three fingers or laundering a 4-finger tail.
                if touch.zTotal > 2 { active = 4; break }
                active += 1
                x += Double(position.x)
                y += Double(position.y)
            }
        }
        let key = UInt(bitPattern: device)
        TrackpadGestureMonitor.shared.queue.async {
            TrackpadGestureMonitor.shared.process(key: key, time: timestamp,
                                                  count: active, x: x, y: y)
        }
    }

    private func process(key: UInt, time: Double, count: Int, x: Double, y: Double) {
        guard enabled, var device = devices[key] else { return }
        let frame = ThreeFingerSwipeRecognizer.Frame(
            time: time, contactCount: count,
            x: count > 0 ? x / Double(count) * device.widthMM : 0,
            y: count > 0 ? (1 - y / Double(count)) * device.heightMM : 0
        )
        let fired = device.recognizer.consume(frame)
        devices[key] = device
        if fired {
            let currentGeneration = generation
            queue.async {
                guard self.enabled, self.generation == currentGeneration else { return }
                DispatchQueue.main.async { self.onSave?() }
            }
        }
    }
}
