import Foundation

/// Calibration samples, labelled by display key. Persisted as JSON in UserDefaults.
struct CalibrationData: Codable {
    var samples: [[Double]]
    var labels: [String]
    var date: Date

    private static let defaultsKey = "calibration.v1"

    static func load() -> CalibrationData? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CalibrationData.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Weighted k-nearest-neighbours over standardised features.
struct GazeClassifier {
    /// Relative importance of [yaw, pitch, noseX, noseY, faceX, faceY, pupilX, pupilY].
    static let weights: [Double] = [1.0, 0.8, 1.5, 0.8, 0.5, 0.5, 0.7, 0.4]

    let samples: [[Double]]
    let labels: [String]
    let mean: [Double]
    let scale: [Double]
    let k: Int

    init?(_ data: CalibrationData) {
        guard let dim = data.samples.first?.count, data.samples.count >= 10,
              data.samples.allSatisfy({ $0.count == dim }) else { return nil }
        let n = Double(data.samples.count)
        var mean = [Double](repeating: 0, count: dim)
        for s in data.samples { for i in 0..<dim { mean[i] += s[i] / n } }
        var std = [Double](repeating: 0, count: dim)
        for s in data.samples { for i in 0..<dim { std[i] += pow(s[i] - mean[i], 2) / n } }
        let w = Self.weights.count == dim ? Self.weights : [Double](repeating: 1, count: dim)
        self.mean = mean
        self.scale = (0..<dim).map { w[$0] / max(sqrt(std[$0]), 1e-6) }
        self.samples = data.samples.map { s in (0..<dim).map { (s[$0] - mean[$0]) * w[$0] / max(sqrt(std[$0]), 1e-6) } }
        self.labels = data.labels
        self.k = min(9, data.samples.count)
    }

    /// Returns the most likely display key and a 0–1 confidence (share of neighbour votes).
    func classify(_ features: [Double]) -> (label: String, confidence: Double)? {
        guard features.count == mean.count else { return nil }
        let x = (0..<features.count).map { (features[$0] - mean[$0]) * scale[$0] }
        let nearest = zip(samples, labels)
            .map { (s, l) in (dist: zip(s, x).reduce(0) { $0 + pow($1.0 - $1.1, 2) }, label: l) }
            .sorted { $0.dist < $1.dist }
            .prefix(k)
        var votes: [String: Double] = [:]
        for n in nearest { votes[n.label, default: 0] += 1 / (sqrt(n.dist) + 0.05) }
        let total = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value < $1.value }), total > 0 else { return nil }
        return (best.key, best.value / total)
    }
}
