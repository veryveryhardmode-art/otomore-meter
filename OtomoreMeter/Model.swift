import Foundation

// MARK: - イヤホンの種類

enum EarType: String, CaseIterable, Identifiable, Codable {
    case canal, inner, open, bone, hpclosed, hpopen

    var id: String { rawValue }

    var name: String {
        switch self {
        case .canal: return "カナル型"
        case .inner: return "インナーイヤー型"
        case .open: return "オープンイヤー"
        case .bone: return "骨伝導"
        case .hpclosed: return "密閉型ヘッドホン"
        case .hpopen: return "開放型・オンイヤー"
        }
    }

    var detail: String {
        switch self {
        case .canal: return "耳の穴にゴムを差し込むタイプ"
        case .inner: return "耳に乗せるだけのタイプ"
        case .open: return "耳をふさがない耳掛け・イヤーカフ型"
        case .bone: return "耳の前の骨を振動させるタイプ"
        case .hpclosed: return "耳をすっぽり覆うヘッドホン"
        case .hpopen: return "外側が網目、または耳に乗せるヘッドホン"
        }
    }

    /// 耳に届く音に対して、耳から10cm外側へ漏れる量（dB、125Hz〜8kHzの帯域ごと）
    /// 公開されている聞き比べ（静かな部屋で20cm・1m・真横）に合うよう、全種類を24dB下げてある
    var loss: [Double] {
        switch self {
        case .canal: return [-82, -78, -74, -70, -66, -64, -66]
        case .inner: return [-60, -56, -52, -48, -44, -42, -44]
        case .open: return [-50, -47, -43, -39, -36, -35, -37]
        case .bone: return [-64, -56, -48, -43, -40, -40, -44]
        case .hpclosed: return [-66, -62, -58, -56, -54, -54, -56]
        case .hpopen: return [-44, -42, -39, -37, -35, -34, -36]
        }
    }

    var hasFit: Bool { self == .canal }
}

enum Fit: String, CaseIterable, Identifiable, Codable {
    case tight, normal, loose

    var id: String { rawValue }

    var name: String {
        switch self {
        case .tight: return "ぴったり"
        case .normal: return "ふつう"
        case .loose: return "ゆるい・浅い"
        }
    }

    var offsets: [Double] {
        switch self {
        case .tight: return [0, 0, 0, 0, 0, 0, 0]
        case .normal: return [5, 4, 4, 3, 3, 3, 3]
        case .loose: return [14, 12, 10, 9, 8, 8, 8]
        }
    }
}

enum Loudness: String, CaseIterable, Identifiable, Codable {
    case quiet, normal, loud

    var id: String { rawValue }

    var name: String {
        switch self {
        case .quiet: return "静かめ"
        case .normal: return "ふつう"
        case .loud: return "大きめ"
        }
    }

    var example: String {
        switch self {
        case .quiet: return "クラシック・弾き語り・ラジオなど"
        case .normal: return "ふつうのポップス"
        case .loud: return "EDM・ロック・アニソンなど音圧の高い曲"
        }
    }

    var db: Double {
        switch self {
        case .quiet: return -6
        case .normal: return 0
        case .loud: return 3
        }
    }
}

// MARK: - 場面と判定

struct Place: Identifiable {
    let id: String
    let name: String
    let whereText: String
    let distance: Double
    let dBA: Double
    let shape: [Double]
}

struct PlaceEval {
    let ambient: [Double]
    let neighbor: [Double?]
    let margin: [Double?]
    let worstMargin: Double
    let worstBand: Int
    let level: Int
    /// いちばん目立つ帯域の漏れが「測りきれず、これ以下」という上限値かどうか
    var uncertain: Bool = false
}

// MARK: - 実測の結果

struct MeasureResult: Codable, Equatable {
    var date: Date
    var volume: Double
    var routeName: String
    var ambientDb: [Double?]
    var leak10: [Double?]
    var detected: [Bool]
    var calibration: Double
    var ambientA: Double?

    var detectedCount: Int { detected.filter { $0 }.count }
}

enum MeasureError: LocalizedError {
    case cancelled, noHeadphoneOutput, noBuiltInMic, notBuiltInMic, noInput, silentMic, zeroVolume, toneNotReady

    var errorDescription: String? {
        switch self {
        case .cancelled: return "中止しました。"
        case .noHeadphoneOutput: return "イヤホンから音を出せませんでした。イヤホンがつながっているか確認してください。"
        case .noBuiltInMic: return "iPhoneのマイクが見つかりませんでした。"
        case .notBuiltInMic: return "iPhoneのマイクに切り替えられませんでした。イヤホンを一度つなぎ直してから、もう一度試してください。"
        case .noInput: return "マイクの音を受け取れませんでした。もう一度試してください。"
        case .silentMic: return "マイクに音が入っていませんでした。ほかのアプリがマイクを使っていないか確認してください。"
        case .zeroVolume: return "音量が0になっています。ふだん聴く音量にしてから測ってください。"
        case .toneNotReady: return "テスト音を準備できませんでした。"
        }
    }
}

// MARK: - 計算モデル

enum Model {
    static let bandLabels = ["125", "250", "500", "1k", "2k", "4k", "8k"]
    static let bandFreqs: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]
    /// A特性（オクターブ中心）
    static let aWeight: [Double] = [-16.1, -8.6, -3.2, 0, 1.2, 1.0, -1.1]
    /// 最小可聴値の目安（dB SPL）
    static let hearing: [Double] = [22, 11, 4, 2, -1, -5, 13]
    /// 一般的な音楽の帯域バランス
    static let music: [Double] = [0, 0, -2, -5, -8, -12, -17]

    static let shapeQuiet: [Double] = [0, -3, -7, -11, -16, -22, -30]
    static let shapeOffice: [Double] = [-2, -2, -3, -6, -10, -16, -24]
    static let shapeBabble: [Double] = [-10, -5, 0, -2, -7, -13, -21]
    static let shapeTrain: [Double] = [0, -1, -4, -9, -15, -21, -29]

    /// 最大音量のときに耳に届く音（dBA）
    static let maxEar = 100.0
    /// 反響ぶん（10cm地点比）
    static let reverbDb = -26.0
    /// テスト音の大きさ（dBFS）と、ふつうの曲の大きさ（dBFS）
    static let testToneDbfs = -15.0
    static let musicDbfs = -12.0
    /// 実測のとき、iPhoneのマイクからイヤホンまでの距離（m）
    static let micDistance = 0.03
    /// iPhoneのマイクの感度の目安（dBFS → dB SPL）
    static let micCalibration = 120.0
    /// 「測った場所」で隣の席の人までの距離（m）
    static let neighborDistance = 0.55

    static let places: [Place] = [
        Place(id: "elev", name: "エレベーター", whereText: "すぐ隣", distance: 0.5, dBA: 40, shape: shapeQuiet),
        Place(id: "lib", name: "図書館・自習室", whereText: "隣の席", distance: 0.7, dBA: 40, shape: shapeQuiet),
        Place(id: "shinStop", name: "新幹線（停車中）", whereText: "隣の席", distance: 0.55, dBA: 50, shape: shapeQuiet),
        Place(id: "office", name: "オフィス", whereText: "隣のデスク", distance: 0.9, dBA: 50, shape: shapeOffice),
        Place(id: "cafe", name: "カフェ", whereText: "隣の席", distance: 0.7, dBA: 60, shape: shapeBabble),
        Place(id: "shinRun", name: "新幹線（走行中）", whereText: "隣の席", distance: 0.55, dBA: 68, shape: shapeTrain),
        Place(id: "train", name: "満員電車", whereText: "密着して立つ", distance: 0.3, dBA: 75, shape: shapeTrain),
        Place(id: "subway", name: "地下鉄（走行中）", whereText: "隣の席", distance: 0.5, dBA: 80, shape: shapeTrain)
    ]

    static let levelNames = ["聞こえない", "ほぼ気づかれない", "気づく人は気づく", "気になる", "曲までわかる"]
    static let levelDescs = [
        "隣の人には聞こえません。",
        "周りが静かになった瞬間だけ、かすかに聞こえることがあります。",
        "シャカシャカ音として聞こえています。",
        "隣の人が気にしやすいレベルです。",
        "何の曲か聞き取れるほど漏れています。"
    ]

    /// 音量（%）→ dB。AirPodsで実測された10%ごとの値（最大音量を0dBとする）
    static let volCurve: [(pct: Double, db: Double)] = [
        (1, -70), (10, -60.8), (20, -51.1), (30, -42.4), (40, -35.1), (50, -28.2),
        (60, -22.2), (70, -15.9), (80, -10.2), (90, -4.9), (100, 0)
    ]

    static func volDb(_ pct: Double) -> Double {
        guard pct >= 1 else { return -Double.infinity }
        for i in 0..<(volCurve.count - 1) {
            let a = volCurve[i]
            let b = volCurve[i + 1]
            if pct <= b.pct {
                return a.db + (pct - a.pct) / (b.pct - a.pct) * (b.db - a.db)
            }
        }
        return 0
    }

    static func volPct(_ db: Double) -> Double {
        if db >= 0 { return 100 }
        guard db >= volCurve[0].db else { return 0 }
        for i in 0..<(volCurve.count - 1) {
            let a = volCurve[i]
            let b = volCurve[i + 1]
            if db <= b.db {
                return a.pct + (db - a.db) / (b.db - a.db) * (b.pct - a.pct)
            }
        }
        return 100
    }

    static func aSum(_ levels: [Double?]) -> Double {
        var s = 0.0
        for i in 0..<min(levels.count, aWeight.count) {
            if let v = levels[i], v.isFinite {
                s += pow(10, (v + aWeight[i]) / 10)
            }
        }
        return s > 0 ? 10 * log10(s) : -Double.infinity
    }

    static func bandsFromA(_ la: Double, shape: [Double]) -> [Double] {
        let k = la - aSum(shape.map { Optional($0) })
        return shape.map { $0 + k }
    }

    static func distanceFactor(_ d: Double) -> Double {
        10 * log10(pow(0.1 / d, 2) + pow(10, reverbDb / 10))
    }

    static func levelOf(_ m: Double) -> Int {
        if m.isNaN { return 0 }
        if m <= -12 { return 0 }
        if m <= -6 { return 1 }
        if m <= 0 { return 2 }
        if m <= 8 { return 3 }
        return 4
    }

    static func earLevel(volumePct: Double, loudness: Loudness) -> Double {
        maxEar + volDb(volumePct) + loudness.db
    }

    static func estimatedLeak(type: EarType, fit: Fit, volumePct: Double, loudness: Loudness) -> [Double?] {
        let ear = bandsFromA(earLevel(volumePct: volumePct, loudness: loudness), shape: music)
        var out: [Double?] = []
        for i in 0..<ear.count {
            let v: Double = ear[i] + type.loss[i] + (type.hasFit ? fit.offsets[i] : 0)
            out.append(v)
        }
        return out
    }

    static func evaluate(leak: [Double?], ambient: [Double], distance: Double, upperBound: [Bool]?) -> PlaceEval {
        let e = evaluate(leak: leak, ambient: ambient, distance: distance)
        guard let ub = upperBound, e.worstBand >= 0, e.worstBand < ub.count, ub[e.worstBand] else { return e }
        var u = e
        u.uncertain = true
        return u
    }

    static func evaluate(leak: [Double?], place: Place, upperBound: [Bool]?) -> PlaceEval {
        evaluate(leak: leak, ambient: bandsFromA(place.dBA, shape: place.shape), distance: place.distance, upperBound: upperBound)
    }

    /// iPhoneマイク自身の雑音（白色雑音32dB SPLを帯域ごとに分けた目安）
    static let micNoiseFloor: [Double] = bandFreqs.map { 32 + 10 * log10(0.7071 * $0 / 24000) }

    /// 「測った場所」の判定に使う周りの音。マイクの雑音に近い帯域は、本当の周りの音がもっと小さいかもしれないので6dB小さめに見積もる
    static func hereAmbient(_ measured: [Double?]) -> [Double] {
        var out: [Double] = []
        for i in 0..<bandFreqs.count {
            guard i < measured.count, let v = measured[i] else {
                out.append(-Double.infinity)
                continue
            }
            out.append(v > micNoiseFloor[i] + 6 ? v : v - 6)
        }
        return out
    }

    /// 漏れ音を「検出した」とみなす比（テスト音のときのパワー ÷ 周りの音だけのパワー）
    static let detectRatio = 1.5

    static func evaluate(leak: [Double?], ambient: [Double], distance: Double) -> PlaceEval {
        let df = distanceFactor(distance)
        var neighbor: [Double?] = []
        var margin: [Double?] = []
        var worst = -Double.infinity
        var worstBand = -1
        for i in 0..<ambient.count {
            if i < leak.count, let v = leak[i], v.isFinite {
                let x = v + df + 1  // +1dB: 反対側の耳のぶん
                let g = x - max(ambient[i], hearing[i])
                neighbor.append(x)
                margin.append(g)
                if g > worst {
                    worst = g
                    worstBand = i
                }
            } else {
                neighbor.append(nil)
                margin.append(nil)
            }
        }
        var level = levelOf(worst)
        // 「曲までわかる」は、歌やメロディの帯域（500Hz〜2kHz）も聞こえているときだけ
        var mid = -Double.infinity
        for i in [2, 3, 4] where i < margin.count {
            if let g = margin[i], g > mid { mid = g }
        }
        if level == 4 && !(mid > 0) { level = 3 }
        return PlaceEval(ambient: ambient, neighbor: neighbor, margin: margin,
                         worstMargin: worst, worstBand: worstBand, level: level)
    }

    static func evaluate(leak: [Double?], place: Place) -> PlaceEval {
        evaluate(leak: leak, ambient: bandsFromA(place.dBA, shape: place.shape), distance: place.distance)
    }

    /// その場面で「ほぼ気づかれない」に収まる音量（%）
    static func safeVolumePct(current: Double, worstMargin: Double) -> Double {
        let vb = volDb(current)
        guard vb.isFinite, worstMargin.isFinite else { return 100 }
        return volPct(vb + (-6 - worstMargin))
    }

    /// 音量（%）→ iPhoneの音量ボタンの段階（0〜16）
    static func steps(fromPct p: Double) -> Int {
        max(0, min(16, Int((p / 6.25 + 1e-6).rounded(.down))))
    }

    /// 周りの音とテスト音のバンドパワー（フルスケール比）から、耳から10cmの漏れ音（ふつうの曲に換算）を求める
    static func computeMeasurement(ambient: [Double], tone: [Double], valid: [Bool], volume: Double,
                                   calibration k: Double, routeName: String) throws -> MeasureResult {
        let nb = bandFreqs.count
        guard ambient.count == nb, tone.count == nb else { throw MeasureError.noInput }
        guard ambient.contains(where: { $0 > 0 }) else { throw MeasureError.silentMic }
        guard volume >= 0.01 else { throw MeasureError.zeroVolume }
        var ambDb = [Double?](repeating: nil, count: nb)
        var leak10 = [Double?](repeating: nil, count: nb)
        var detected = [Bool](repeating: false, count: nb)
        let distAdj = 20 * log10(micDistance / 0.1)
        let musicAdj = musicDbfs - testToneDbfs
        // 125Hz帯はスマホのマイクでは不安定なので使わない
        for i in 1..<nb {
            if i < valid.count && !valid[i] { continue }
            let pa = ambient[i]
            let pt = tone[i]
            guard pa > 0, pt > 0 else { continue }
            ambDb[i] = 10 * log10(pa) + k
            let leakP: Double
            if pt > pa * detectRatio {
                leakP = pt - pa
                detected[i] = true
            } else {
                // 周りの音に埋もれて検出できない → 「これ以下」という上限値
                leakP = pa * (detectRatio - 1)
            }
            leak10[i] = 10 * log10(leakP) + k + distAdj + musicAdj
        }
        let a = aSum(ambDb)
        return MeasureResult(date: Date(), volume: volume, routeName: routeName, ambientDb: ambDb,
                             leak10: leak10, detected: detected, calibration: k,
                             ambientA: a.isFinite ? a : nil)
    }
}

func signedText(_ v: Double) -> String {
    guard v.isFinite else { return "—" }
    let r = Int(v.rounded())
    return r > 0 ? "+\(r)" : "\(r)"
}
