import Foundation

/// Spots deliberate one-eyed winks while ignoring ordinary blinks (both eyes) and squints.
///
/// Openness is judged relative to each eye's own recent "open" baseline, so it adapts to
/// your face, distance from the camera and head angle.
struct WinkDetector {
    /// Below this fraction of baseline an eye counts as shut; above `openRatio` as open.
    var closedRatio = 0.6
    var openRatio = 0.82
    /// How long one eye must stay shut (with the other open) to count as a wink.
    var minDuration: CFAbsoluteTime = 0.09  // 3 consecutive frames at 20 fps

    private var leftHistory: [Double] = []
    private var rightHistory: [Double] = []
    private var winkStart: CFAbsoluteTime?
    private var armed = true

    /// Latest openness relative to baseline (1 = normally open), for the menu readout.
    private(set) var relative: (left: Double, right: Double) = (1, 1)

    /// True if either eye is noticeably narrowed (gaze features are unreliable then).
    var eyesNarrowed: Bool { min(relative.left, relative.right) < openRatio }

    /// Feed one frame. Returns the time the wink began when a wink is recognised (once per wink).
    mutating func update(left: Double, right: Double, at now: CFAbsoluteTime) -> CFAbsoluteTime? {
        let baseL = Self.baseline(&leftHistory, left), baseR = Self.baseline(&rightHistory, right)
        guard baseL > 0, baseR > 0 else { return nil }
        relative = (left / baseL, right / baseR)

        let (l, r) = relative
        let bothOpen = l > openRatio && r > openRatio
        let wink = (l < closedRatio && r > openRatio) || (r < closedRatio && l > openRatio)

        if bothOpen { armed = true }
        guard wink, armed else {
            winkStart = nil
            return nil
        }
        let start = winkStart ?? now
        winkStart = start
        if now - start >= minDuration {
            armed = false  // one trigger per wink; re-arm once both eyes reopen
            winkStart = nil
            return start
        }
        return nil
    }

    mutating func reset() {
        winkStart = nil
        relative = (1, 1)
    }

    /// Upper-quartile of the last ~3 s: tracks the open-eye shape while ignoring blinks.
    private static func baseline(_ history: inout [Double], _ value: Double) -> Double {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        guard history.count >= 8 else { return 0 }
        let sorted = history.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.75)]
    }
}
