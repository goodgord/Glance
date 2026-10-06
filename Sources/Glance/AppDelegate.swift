import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    /// How eager Glance is to switch: gaze dwell time and how long to hold off after typing/clicking.
    private enum Responsiveness: String, CaseIterable {
        case snappy = "Snappy", balanced = "Balanced", relaxed = "Relaxed"
        var dwell: Double { [.snappy: 0.25, .balanced: 0.45, .relaxed: 0.8][self]! }
        var typingGrace: Double { [.snappy: 0.5, .balanced: 0.9, .relaxed: 1.5][self]! }
    }

    private let tracker = GazeTracker()
    private var statusItem: NSStatusItem!
    private var calibration: CalibrationController?
    private var classifier: GazeClassifier?
    private var displays = FocusSwitcher.currentDisplays()

    // Live state
    private var smoothed: [Double]?
    private var faceVisible = false
    private var lookingAt: (label: String, confidence: Double)?
    private var candidate: CGDirectDisplayID?
    private var candidateSince: CFAbsoluteTime = 0
    private var lastSwitch: CFAbsoluteTime = 0
    private var cameraError: String?

    // Menu items updated live
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
    private let warpItem = NSMenuItem(title: "Move Pointer Too", action: #selector(toggleWarp), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")

    // Settings
    private let defaults = UserDefaults.standard
    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var warpPointer: Bool {
        get { defaults.bool(forKey: "warpPointer") }
        set { defaults.set(newValue, forKey: "warpPointer") }
    }
    private var responsiveness: Responsiveness {
        get { Responsiveness(rawValue: defaults.string(forKey: "responsiveness") ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "responsiveness") }
    }
    private var cameraID: String? {
        get { defaults.string(forKey: "cameraID") }
        set { defaults.set(newValue, forKey: "cameraID") }
    }

    private let minConfidence = 0.62
    private let switchCooldown = 0.6
    private let clickGrace = 1.0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()

        if let data = CalibrationData.load() { classifier = GazeClassifier(data) }
        if !FocusSwitcher.isTrusted { FocusSwitcher.promptForAccessibility() }

        tracker.onSample = { [weak self] in self?.handle($0) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displays = FocusSwitcher.currentDisplays()
            self?.refreshUI()
        }

        // First run from /Applications: default to launching at login (toggle in the menu).
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !defaults.bool(forKey: "didSetUpLoginItem") {
            defaults.set(true, forKey: "didSetUpLoginItem")
            try? SMAppService.mainApp.register()
        }

        if enabled { startTracking() }
        refreshUI()

        if classifier == nil || !calibrationMatchesDisplays() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.calibrate() }
        }
    }

    private func startTracking() {
        tracker.start(cameraID: cameraID) { [weak self] ok in
            self?.cameraError = ok ? nil : "Camera unavailable — check System Settings › Privacy › Camera"
            self?.refreshUI()
        }
    }

    // MARK: - Gaze loop

    private func handle(_ sample: GazeSample?) {
        if let calibration {
            calibration.feed(sample)
            return
        }

        let wasVisible = faceVisible
        faceVisible = sample != nil
        guard let sample else {
            smoothed = nil
            candidate = nil
            lookingAt = nil
            if wasVisible { refreshUI() }
            return
        }

        // Light exponential smoothing to calm Vision's jitter.
        if let prev = smoothed, prev.count == sample.features.count {
            smoothed = zip(prev, sample.features).map { 0.55 * $1 + 0.45 * $0 }
        } else {
            smoothed = sample.features
        }

        guard let classifier, let result = classifier.classify(smoothed!),
              let target = displays[result.label] else {
            lookingAt = nil
            refreshUI()
            return
        }
        let previousKey = lookingAt?.label
        lookingAt = result
        if previousKey != result.label || !wasVisible { refreshUI() } else { updateStatusLine() }

        guard enabled, result.confidence >= minConfidence else { candidate = nil; return }

        let now = CFAbsoluteTimeGetCurrent()
        if candidate != target.id {
            candidate = target.id
            candidateSince = now
            return
        }

        let r = responsiveness
        guard now - candidateSince >= r.dwell,
              now - lastSwitch >= switchCooldown,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) >= r.typingGrace,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown) >= clickGrace,
              CGEventSource.buttonState(.combinedSessionState, button: .left) == false,
              FocusSwitcher.isTrusted,
              FocusSwitcher.focusedDisplay() != target.id else { return }

        FocusSwitcher.focus(display: target.id, warpPointer: warpPointer)
        lastSwitch = now
    }

    private func calibrationMatchesDisplays() -> Bool {
        guard let labels = CalibrationData.load()?.labels else { return false }
        return Set(labels) == Set(displays.keys)
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(withTitle: "Calibrate…", action: #selector(calibrate), keyEquivalent: "c").target = self
        menu.addItem(.separator())

        let respMenu = NSMenu()
        for r in Responsiveness.allCases {
            let item = NSMenuItem(title: r.rawValue, action: #selector(setResponsiveness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r.rawValue
            respMenu.addItem(item)
        }
        let respItem = NSMenuItem(title: "Responsiveness", action: nil, keyEquivalent: "")
        respItem.submenu = respMenu
        menu.addItem(respItem)

        let camItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        camItem.submenu = NSMenu()
        menu.addItem(camItem)

        warpItem.target = self
        menu.addItem(warpItem)
        loginItem.target = self
        menu.addItem(loginItem)

        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        displays = FocusSwitcher.currentDisplays()

        if let camMenu = menu.item(withTitle: "Camera")?.submenu {
            camMenu.removeAllItems()
            let current = cameraID ?? GazeTracker.defaultCamera()?.uniqueID
            for cam in GazeTracker.availableCameras() {
                let item = NSMenuItem(title: cam.localizedName, action: #selector(selectCamera(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = cam.uniqueID
                item.state = cam.uniqueID == current ? .on : .off
                camMenu.addItem(item)
            }
        }
        menu.item(withTitle: "Responsiveness")?.submenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == responsiveness.rawValue ? .on : .off
        }
        refreshUI()
    }

    private func refreshUI() {
        enabledItem.state = enabled ? .on : .off
        warpItem.state = warpPointer ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.isHidden = FocusSwitcher.isTrusted

        let symbol: String
        if !enabled { symbol = "eye.slash" }
        else if cameraError != nil || !FocusSwitcher.isTrusted { symbol = "eye.trianglebadge.exclamationmark" }
        else if faceVisible { symbol = "eye.fill" }
        else { symbol = "eye" }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glance")

        // Show which screen (numbered left to right) you're looking at.
        if enabled, let key = lookingAt?.label, let n = screenNumber(for: key) {
            statusItem.button?.title = " \(n)"
        } else {
            statusItem.button?.title = ""
        }
        updateStatusLine()
    }

    private func updateStatusLine() {
        statusLine.title = {
            if let cameraError { return cameraError }
            if !FocusSwitcher.isTrusted { return "Needs Accessibility access to switch focus" }
            if !enabled { return "Paused" }
            if classifier == nil { return "Not calibrated — choose Calibrate…" }
            if !calibrationMatchesDisplays() { return "Displays changed — please recalibrate" }
            if !faceVisible { return "Can't see you 👀" }
            guard let l = lookingAt, let d = displays[l.label] else { return "Watching…" }
            return "Looking at \(screenNumber(for: l.label) ?? 0): \(d.screen.localizedName) (\(Int(l.confidence * 100))%)"
        }()
    }

    private func screenNumber(for key: String) -> Int? {
        let ordered = displays.sorted { $0.value.screen.frame.minX < $1.value.screen.frame.minX }.map(\.key)
        return ordered.firstIndex(of: key).map { $0 + 1 }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        if enabled { startTracking() } else if calibration == nil { tracker.stop() }
        lookingAt = nil
        faceVisible = false
        refreshUI()
    }

    @objc private func toggleWarp() {
        warpPointer.toggle()
        refreshUI()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn't change Launch at Login", error.localizedDescription)
        }
        refreshUI()
    }

    @objc private func setResponsiveness(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let r = Responsiveness(rawValue: raw) {
            responsiveness = r
        }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        cameraID = sender.representedObject as? String
        tracker.stop()
        if enabled || calibration != nil { startTracking() }
    }

    @objc private func openAccessibility() {
        FocusSwitcher.promptForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func calibrate() {
        guard calibration == nil else { return }
        displays = FocusSwitcher.currentDisplays()
        if !tracker.isRunning { startTracking() }

        let controller = CalibrationController { [weak self] data in
            guard let self else { return }
            self.calibration = nil
            if let data, let clf = GazeClassifier(data) {
                data.save()
                self.classifier = clf
            } else if data != nil || self.classifier == nil {
                self.showAlert("Calibration didn't collect enough data",
                               "Make sure your face is visible to the camera and try again.")
            }
            if !self.enabled { self.tracker.stop() }
            self.smoothed = nil
            self.refreshUI()
        }
        calibration = controller
        controller.start()
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
