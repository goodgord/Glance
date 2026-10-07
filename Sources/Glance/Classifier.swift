import Foundation

/// Calibration samples, labelled by display key. Persisted as JSON in UserDefaults.
struct CalibrationData: Codable {
    var samples: [[Double]]
    var labels: [String]
    /// Which calibration point each sample came from (for cross-validation). Nil in old calibrations.
    var groups: [Int]?
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

    func subset(_ keep: (Int) -> Bool) -> CalibrationData {
        let idx = samples.indices.filter(keep)
        return CalibrationData(samples: idx.map { samples[$0] }, labels: idx.map { labels[$0] },
                               groups: groups.map { g in idx.map { g[$0] } }, date: date)
    }
}

/// Weighted k-nearest-neighbours over standardised features.
///
/// Each feature is weighted by how well it separates *your* screens in calibration
/// (Fisher ratio: spread between screens ÷ spread within a screen). Stacked monitors
/// end up leaning on pitch/vertical features, side-by-side ones on yaw.
struct GazeClassifier {
    let samples: [[Double]]
    let labels: [String]
    let mean: [Double]
    let scale: [Double]
    let featureWeights: [Double]
    let k: Int

    init?(_ data: CalibrationData) {
        guard let dim = data.samples.first?.count, data.samples.count >= 10,
              data.samples.allSatisfy({ $0.count == dim }) else { return nil }
        let n = Double(data.samples.count)

        var mean = [Double](repeating: 0, count: dim)
        for s in data.samples { for i in 0..<dim { mean[i] += s[i] / n } }
        var variance = [Double](repeating: 0, count: dim)
        for s in data.samples { for i in 0..<dim { variance[i] += pow(s[i] - mean[i], 2) / n } }
        let std = variance.map { max(sqrt($0), 1e-6) }

        // Fisher ratio per feature.
        var within = [Double](repeating: 0, count: dim)
        var between = [Double](repeating: 0, count: dim)
        for label in Set(data.labels) {
            let members = data.samples.indices.filter { data.labels[$0] == label }.map { data.samples[$0] }
            let m = Double(members.count)
            for i in 0..<dim {
                let mu = members.reduce(0) { $0 + $1[i] } / m
                between[i] += m * pow(mu - mean[i], 2) / n
                within[i] += members.reduce(0) { $0 + pow($1[i] - mu, 2) } / n
            }
        }
        let fisher = (0..<dim).map { between[$0] / max(within[$0], 1e-12) }
        let maxFisher = max(fisher.max() ?? 1, 1e-12)
        let weights = fisher.map { max(0.15, sqrt($0 / maxFisher)) }

        self.mean = mean
        self.featureWeights = weights
        self.scale = (0..<dim).map { weights[$0] / std[$0] }
        let scale = self.scale
        self.samples = data.samples.map { s in (0..<dim).map { (s[$0] - mean[$0]) * scale[$0] } }
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

    /// Leave-one-calibration-point-out accuracy, overall and per display key.
    /// Honest estimate: each point is judged by a classifier that never saw it.
    static func crossValidate(_ data: CalibrationData) -> (overall: Double, perLabel: [String: Double])? {
        guard let groups = data.groups, groups.count == data.samples.count else { return nil }
        var correct: [String: Int] = [:], total: [String: Int] = [:]
        for g in Set(groups) {
            guard let clf = GazeClassifier(data.subset { groups[$0] != g }) else { continue }
            for i in data.samples.indices where groups[i] == g {
                let truth = data.labels[i]
                total[truth, default: 0] += 1
                if clf.classify(data.samples[i])?.label == truth { correct[truth, default: 0] += 1 }
            }
        }
        let all = total.values.reduce(0, +)
        guard all > 0 else { return nil }
        let perLabel = Dictionary(uniqueKeysWithValues: total.map { label, count in
            (label, Double(correct[label] ?? 0) / Double(count))
        })
        return (Double(correct.values.reduce(0, +)) / Double(all), perLabel)
    }
}
