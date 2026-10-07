import AppKit

/// Full-screen overlays that walk a dot around every display while collecting gaze samples.
final class CalibrationController {
    private struct Target {
        let key: String
        let screen: NSScreen
        let point: CGPoint  // 0–1 within the screen
    }

    private enum Phase { case intro, settle, collect }

    /// 3×3 grid reaching close to the edges (the ambiguous zones between stacked monitors),
    /// visited in a snake so the eyes never jump far within a screen.
    private static let points: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.5, y: 0.92), CGPoint(x: 0.92, y: 0.92),
        CGPoint(x: 0.92, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.08, y: 0.5),
        CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.5, y: 0.08), CGPoint(x: 0.92, y: 0.08),
    ]
    private let introTime = 3.0, settleTime = 0.8, collectTime = 1.0

    private let onFinish: (CalibrationData?) -> Void
    private var targets: [Target] = []
    private var overlays: [String: (window: NSWindow, view: OverlayView)] = [:]
    private var index = 0
    private var phase = Phase.intro
    private var phaseStart = CFAbsoluteTimeGetCurrent()
    private var timer: Timer?
    private var keyMonitor: Any?
    private var samples: [[Double]] = []
    private var labels: [String] = []
    private var groups: [Int] = []

    init(onFinish: @escaping (CalibrationData?) -> Void) {
        self.onFinish = onFinish
    }

    func start() {
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        for screen in screens {
            let key = FocusSwitcher.key(of: FocusSwitcher.displayID(of: screen))
            targets += Self.points.map { Target(key: key, screen: screen, point: $0) }

            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays[key] = (window, view)
        }

        NSApp.activate(ignoringOtherApps: true)
        overlays[targets.first?.key ?? ""]?.window.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(cancelled: true) }  // Esc
            return nil
        }

        phaseStart = CFAbsoluteTimeGetCurrent()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        render()
    }

    /// Feed every tracker sample here while calibrating.
    func feed(_ sample: GazeSample?) {
        guard phase == .collect, let sample, index < targets.count else { return }
        samples.append(sample.features)
        labels.append(targets[index].key)
        groups.append(index)
    }

    private func tick() {
        let elapsed = CFAbsoluteTimeGetCurrent() - phaseStart
        switch phase {
        case .intro where elapsed >= introTime: advance(to: .settle)
        case .settle where elapsed >= settleTime: advance(to: .collect)
        case .collect where elapsed >= collectTime:
            index += 1
            if index >= targets.count { finish(cancelled: false); return }
            advance(to: .settle)
        default: break
        }
        render()
    }

    private func advance(to next: Phase) {
        phase = next
        phaseStart = CFAbsoluteTimeGetCurrent()
    }

    private func render() {
        guard index < targets.count else { return }
        let t = targets[index]
        let elapsed = CFAbsoluteTimeGetCurrent() - phaseStart
        for (key, overlay) in overlays {
            let v = overlay.view
            if key == t.key {
                v.dot = CGPoint(x: t.point.x * v.bounds.width, y: t.point.y * v.bounds.height)
                switch phase {
                case .intro:
                    v.message = "Look at the dot on each screen and follow it.\nTurn your head naturally, the way you normally would.\nEsc cancels."
                    v.progress = 0
                case .settle:
                    v.message = nil
                    v.progress = 0
                case .collect:
                    v.message = nil
                    v.progress = min(1, elapsed / collectTime)
                }
                v.collecting = phase == .collect
            } else {
                v.dot = nil
                v.message = nil
            }
            v.needsDisplay = true
        }
    }

    private func finish(cancelled: Bool) {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()

        // Need a decent number of samples on every display for the result to be useful.
        let perScreen = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        let complete = !cancelled && Set(targets.map(\.key)).allSatisfy { (perScreen[$0] ?? 0) >= 20 }
        onFinish(complete ? CalibrationData(samples: samples, labels: labels, groups: groups, date: Date()) : nil)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    var dot: CGPoint?
    var progress: Double = 0
    var collecting = false
    var message: String?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.78).setFill()
        bounds.fill()

        if let dot {
            let ring = 10 + 46 * (1 - progress)
            let ringRect = CGRect(x: dot.x - ring, y: dot.y - ring, width: ring * 2, height: ring * 2)
            let path = NSBezierPath(ovalIn: ringRect)
            path.lineWidth = 3
            NSColor.white.withAlphaComponent(0.8).setStroke()
            path.stroke()

            let r: CGFloat = 9
            (collecting ? NSColor.systemGreen : NSColor.systemPink).setFill()
            NSBezierPath(ovalIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)).fill()
        }

        if let message {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let rect = CGRect(x: 40, y: bounds.midY + 70, width: bounds.width - 80, height: 120)
            (message as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}
