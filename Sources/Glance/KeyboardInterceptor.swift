import AppKit

/// Watches keystrokes and, on the first key of a new typing burst, lets the delegate move focus
/// before the keys are delivered. Keys typed mid-burst always pass straight through.
final class KeyboardInterceptor {
    /// Cheap, synchronous check on the first key of a burst: should we hold keys while deciding?
    var shouldHold: (() -> Bool)?
    /// Called on the main queue while keys are held. Return true if focus was moved
    /// (keys are then delivered after a short delay so the new window is ready).
    var redirect: (() -> Bool)?
    /// Keyboard idle time that marks the start of a new burst.
    var burstGap: CFAbsoluteTime = 0.9

    private static let marker: Int64 = 0x474C_4E43  // "GLNC": events we re-post ourselves
    private static let activationDelay: TimeInterval = 0.07

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastKeyDown: CFAbsoluteTime = 0
    private var holding = false
    private var held: [CGEvent] = []

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CGRequestListenEventAccess()  // Input Monitoring may also need granting
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        flush()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }
        if holding {
            if let copy = event.copy() { held.append(copy) }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let now = CFAbsoluteTimeGetCurrent()
        let startsBurst = now - lastKeyDown >= burstGap
        lastKeyDown = now

        guard startsBurst,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              !Self.isSystemShortcut(event),
              shouldHold?() == true,
              let copy = event.copy() else {
            return Unmanaged.passUnretained(event)
        }

        holding = true
        held = [copy]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.redirect?() == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDelay) { self.flush() }
            } else {
                self.flush()
            }
        }
        return nil
    }

    private func flush() {
        let events = held
        held = []
        holding = false
        for e in events {
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cgSessionEventTap)
        }
    }

    /// Cmd-Tab / Cmd-` switch apps or windows themselves; leave them alone.
    private static func isSystemShortcut(_ event: CGEvent) -> Bool {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        return event.flags.contains(.maskCommand) && (key == 48 || key == 50)  // Tab, `
    }
}
