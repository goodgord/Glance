import AppKit
import ApplicationServices

/// Display identification and moving keyboard focus to the topmost window on a display.
enum FocusSwitcher {

    // MARK: Displays

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable-ish key: hardware identity plus position, so rearranging monitors invalidates calibration.
    static func key(of display: CGDirectDisplayID) -> String {
        let b = CGDisplayBounds(display)
        return "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))@\(Int(b.minX)),\(Int(b.minY))"
    }

    /// Current displays keyed by `key(of:)`.
    static func currentDisplays() -> [String: (id: CGDirectDisplayID, screen: NSScreen)] {
        var out: [String: (CGDirectDisplayID, NSScreen)] = [:]
        for s in NSScreen.screens {
            let id = displayID(of: s)
            out[key(of: id)] = (id, s)
        }
        return out
    }

    static func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return count > 0 ? id : nil
    }

    // MARK: Accessibility

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// Display holding the centre of the currently focused window.
    static func focusedDisplay() -> CGDirectDisplayID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, let frame = frame(of: win as! AXUIElement) else {
            return nil
        }
        return display(containing: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Raise and focus the frontmost normal window whose centre is on `display`.
    @discardableResult
    static func focus(display: CGDirectDisplayID, warpPointer: Bool) -> Bool {
        let bounds = CGDisplayBounds(display)
        defer {
            if warpPointer, let mouse = CGEvent(source: nil)?.location, !bounds.contains(mouse) {
                CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        guard let target = topWindow(on: bounds),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return false }

        let axApp = AXUIElementCreateApplication(target.pid)
        if let axWin = axWindow(of: axApp, matching: target.bounds) {
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return true
    }

    private static func topWindow(on bounds: CGRect) -> (pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {  // front-to-back order
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 80, rect.height > 80,
                  bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            return (pid, rect)
        }
        return nil
    }

    private static func axWindow(of app: AXUIElement, matching rect: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            guard let f = frame(of: w) else { return false }
            return abs(f.minX - rect.minX) < 4 && abs(f.minY - rect.minY) < 4
                && abs(f.width - rect.width) < 4 && abs(f.height - rect.height) < 4
        }
    }

    /// AX frame in global top-left-origin coordinates (same space as CGWindowList / CGDisplayBounds).
    private static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
}
