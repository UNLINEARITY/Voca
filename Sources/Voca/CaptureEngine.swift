import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum CaptureResult {
    case success(text: String, appName: String?, bundleID: String?)
    case emptySelection
    case notTrusted
    case secureField
}

/// 取词引擎：AX API 优先，失败降级为模拟 ⌘C（读完恢复原剪贴板）
final class CaptureEngine {
    static let shared = CaptureEngine()

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

        if focusedElementIsSecure() { return .secureField }

        if let text = axSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .success(text: text, appName: appName, bundleID: bundleID)
        }

        if let text = copyFallback()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .success(text: text, appName: appName, bundleID: bundleID)
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
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.snapshot()
        let changeCountBefore = pasteboard.changeCount

        postCmdC()

        var changed = false
        for _ in 0..<40 { // 最多等待 400ms
            Thread.sleep(forTimeInterval: 0.01)
            if pasteboard.changeCount != changeCountBefore {
                changed = true
                break
            }
        }

        // 只有剪贴板真的变化了才读取，避免误收用户剪贴板里的旧内容
        guard changed, let text = pasteboard.string(forType: .string) else {
            return nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.restore(saved)
        }
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
        guard !snapshot.isEmpty else { return }
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
