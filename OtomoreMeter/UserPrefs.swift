import Foundation

/// 設定と実測結果を保存する
final class UserPrefs: ObservableObject {
    @Published var loudness: Loudness { didSet { save() } }
    @Published var fit: Fit { didSet { save() } }
    /// イヤホン名 → 手動で選んだ種類
    @Published var overrides: [String: EarType] { didSet { save() } }
    /// イヤホン名 → 最後の実測結果
    @Published var measurements: [String: MeasureResult] { didSet { save() } }
    @Published var useMeasured: Bool { didSet { save() } }
    @Published var micOffset: Double { didSet { save() } }

    private struct Stored: Codable {
        var loudness: Loudness
        var fit: Fit
        var overrides: [String: EarType]
        var measurements: [String: MeasureResult]
        var useMeasured: Bool
        var micOffset: Double
    }

    private static let key = "otomore.prefs.v1"

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    init() {
        var s = Stored(loudness: .normal, fit: .normal, overrides: [:], measurements: [:], useMeasured: true, micOffset: 0)
        if let data = UserDefaults.standard.data(forKey: UserPrefs.key),
           let decoded = try? UserPrefs.makeDecoder().decode(Stored.self, from: data) {
            s = decoded
        }
        _loudness = Published(initialValue: s.loudness)
        _fit = Published(initialValue: s.fit)
        _overrides = Published(initialValue: s.overrides)
        _measurements = Published(initialValue: s.measurements)
        _useMeasured = Published(initialValue: s.useMeasured)
        _micOffset = Published(initialValue: s.micOffset)
    }

    private func save() {
        let s = Stored(loudness: loudness, fit: fit, overrides: overrides, measurements: measurements,
                       useMeasured: useMeasured, micOffset: micOffset)
        if let data = try? UserPrefs.makeEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: UserPrefs.key)
        }
    }
}
