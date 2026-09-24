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
import ApplicationServices
import Carbon.HIToolbox

enum CaptureResult {
    case success(text: String, appName: String?, bundleID: String?, url: String?)
    case emptySelection
    case notTrusted
    case secureField
}

extension Notification.Name {
    /// ⌘C 降级取词的模拟复制与剪贴板恢复已全部结束
    static let simulatedCopyEnded = Notification.Name("VocaSimulatedCopyEnded")
}

/// 前台浏览器当前标签页 URL（Apple Events 查询；须在主线程调用）
enum BrowserTabURL {
    /// bundleID → AppleScript 目标名（Chromium 系共用同一套字典；Firefox 无接口不收录）
    private static let targets: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    static func isSupportedBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targets[bundleID] != nil
    }

    /// 返回当前标签页 URL；非受支持浏览器、无窗口、未授权或非 http(s) 链接时返回 nil。
    /// 经 osascript 子进程执行，可在任意线程调用；浏览器忙时只阻塞调用线程，不卡 UI。
    static func current(bundleID: String?) -> String? {
        guard let bundleID, let name = targets[bundleID] else { return nil }
        let isChromium = name != "Safari"
        let source = """
        tell application "\(name)"
            if (count of windows) > 0 then
                return URL of \(isChromium ? "active tab of front window" : "front document")
            end if
        end tell
        """
        guard let output = runAppleScript(source) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("http") else { return nil }
        return value
    }

    /// 子进程执行 AppleScript；失败（无窗口、未授权等）属常规降级，静默返回 nil
    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdout
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            NSLog("Voca: osascript 启动失败：%@", "\(error)")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 取词引擎：AX API 优先，失败降级为模拟 ⌘C（读完恢复原剪贴板）
final class CaptureEngine {
    static let shared = CaptureEngine()

    /// ⌘C 降级进行中：剪贴板监听应暂停，避免记录我们模拟的复制与恢复动作
    static var isSimulatingCopy: Bool {
        simLock.lock(); defer { simLock.unlock() }
        return _isSimulatingCopy
    }
    private static let simLock = NSLock()
    private static var _isSimulatingCopy = false

    static func beginSimulatedCopy() -> Bool {
        simLock.lock(); defer { simLock.unlock() }
        guard !_isSimulatingCopy else { return false }
        _isSimulatingCopy = true
        return true
    }

    static func endSimulatedCopy(recordCurrent: Bool? = nil) {
        simLock.lock()
        _isSimulatingCopy = false
        simLock.unlock()
        guard let recordCurrent else { return }
        NotificationCenter.default.post(
            name: .simulatedCopyEnded,
            object: nil,
            userInfo: ["recordCurrent": recordCurrent]
        )
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权引导
    func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 在后台线程调用
    func capture() -> CaptureResult {
        guard isTrusted else { return .notTrusted }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName
        let bundleID = frontApp?.bundleIdentifier
        // 前台是受支持浏览器时查询当前标签页 URL（子进程执行，无需主线程）
        let url = BrowserTabURL.current(bundleID: bundleID)

        if focusedElementIsSecure() { return .secureField }

        if let text = axSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .success(text: text, appName: appName, bundleID: bundleID, url: url)
        }

        if let text = copyFallback()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .success(text: text, appName: appName, bundleID: bundleID, url: url)
        }

        return .emptySelection
    }

    // MARK: - Accessibility

    private func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard status == .success else { return nil }
        return value as? String
    }

    private func focusedElementIsSecure() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let raw = focused,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return false }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        )
        guard roleStatus == .success, let roleString = role as? String else { return false }
        return roleString == "AXSecureTextField"
    }

    // MARK: - ⌘C 降级路径

    private func copyFallback() -> String? {
        copyFallback(on: .general, postCopy: postCmdC)
    }

    func copyFallback(on pasteboard: NSPasteboard, postCopy: () -> Void) -> String? {
        guard Self.beginSimulatedCopy() else { return nil }
        var restorationScheduled = false
        defer {
            if !restorationScheduled { Self.endSimulatedCopy() }
        }
        let saved = pasteboard.snapshot()
        let changeCountBefore = pasteboard.changeCount

        // 模拟复制与随后的恢复都不计入剪贴板历史(否则一次取词会多出两条假记录)
        postCopy()

        var changed = false
        for _ in 0..<40 { // 最多等待 400ms
            Thread.sleep(forTimeInterval: 0.01)
            if pasteboard.changeCount != changeCountBefore {
                changed = true
                break
            }
        }

        // 只有剪贴板真的变化了才读取，避免误收用户剪贴板里的旧内容
        guard changed else { return nil }
        let text = pasteboard.string(forType: .string)
        let simulatedChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let userCopiedSince = pasteboard.changeCount != simulatedChangeCount
            if !userCopiedSince { pasteboard.restore(saved) }
            // 用户在等待恢复期间又复制时，不覆盖其新内容，并交给监听器补记。
            Self.endSimulatedCopy(recordCurrent: userCopiedSince)
        }
        restorationScheduled = true
        return text
    }

    private func postCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: false
        )
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - 剪贴板快照/恢复

private extension NSPasteboard {
    struct ItemSnapshot {
        let types: [NSPasteboard.PasteboardType]
        let data: [Data]
    }

    func snapshot() -> [ItemSnapshot] {
        return pasteboardItems?.map { item in
            let types = item.types
            let data = types.map { item.data(forType: $0) ?? Data() }
            return ItemSnapshot(types: types, data: data)
        } ?? []
    }

    func restore(_ snapshot: [ItemSnapshot]) {
        clearContents()
        for entry in snapshot {
            let item = NSPasteboardItem()
            for (type, data) in zip(entry.types, entry.data) {
                item.setData(data, forType: type)
            }
            writeObjects([item])
        }
    }
}
