import Foundation

// 実測モードの検証：アプリと同じ BandAnalyzer と Model.computeMeasurement に、
// 「周りの騒音＋イヤホンから漏れたテスト音＋マイクの雑音」を合成した録音を流し、
// 答え（合成に使った本当の漏れ量）とどれだけ合うかを数える。
// 音はどこにも再生しない（すべて数値の計算だけ）。

let fs = 48000.0
let chunk = 4096
let K = 120.0                 // マイク感度（合成とアプリで同じ値＝感度は正しく合っている前提）
let micNoiseDb = 32.0         // iPhoneマイク自身の雑音（dB SPL、全帯域）
let musicAdj = Model.musicDbfs - Model.testToneDbfs
let NB = Model.bandFreqs.count

func f1(_ v: Double?) -> String {
    guard let v = v, v.isFinite else { return "  —  " }
    return String(format: "%5.1f", v)
}
func s1(_ v: Double) -> String { v.isFinite ? String(format: "%+.1f", v) : "—" }
func pct(_ a: Int, _ b: Int) -> String { b > 0 ? String(format: "%5.1f%%", 100 * Double(a) / Double(b)) : "  —  " }

struct Env { let name: String; let dBA: Double; let shape: [Double] }
let envs = [
    Env(name: "静かな部屋35dB", dBA: 35, shape: Model.shapeQuiet),
    Env(name: "ふつうの部屋40dB", dBA: 40, shape: Model.shapeQuiet),
    Env(name: "オフィス50dB", dBA: 50, shape: Model.shapeOffice),
    Env(name: "カフェ60dB", dBA: 60, shape: Model.shapeBabble),
    Env(name: "新幹線の車内68dB", dBA: 68, shape: Model.shapeTrain)
]
let types: [EarType] = [.canal, .inner, .open, .bone, .hpclosed, .hpopen]
let steps = [4, 8, 12, 16]

print("=== 実測モードの合成録音シミュレーション ===")
print("改良: 帯域パワーは約85msごとの中央値 / 検出の基準は1.76dB（1.5倍） / マイク雑音に近い帯域は周りの音を6dB小さめに見積もる")
print("条件: サンプリング48kHz / 4096サンプルずつ処理 / 周りの音3.0秒 → テスト音開始(Bluetooth遅れ0.25秒) → 0.7秒後から3.5秒")
print("      マイク感度K=\(Int(K)) / マイク雑音\(Int(micNoiseDb))dB / 騒音は帯域ごとに±2dBでゆっくり揺らぐ")
print("      実機のイヤホンはモデル値から帯域ごとに±3dBずれている / マイクとイヤホンの距離は2〜5cmのどこか（アプリは3cmとして計算）")
let t0 = Date()
let ambientBank = BandSignalBank(sampleRate: fs, seconds: 6, toneCount: 600, seed: 11)
let leakBank = BandSignalBank(sampleRate: fs, seconds: 2, toneCount: 600, seed: 22)
print(String(format: "合成用の音源を生成: %.1f秒", Date().timeIntervalSince(t0)))

struct Trial {
    let env: Env
    let type: EarType?
    let step: Int
    let micDist: Double
    let dev: [Double]
    let burst: (inTone: Bool, gainDb: Double)?
    let seed: UInt64
}

struct Outcome {
    let trial: Trial
    let trueLeak10: [Double?]
    let trueAmb: [Double]
    let leakAtMic: [Double]
    let result: MeasureResult
    let hereTrue: PlaceEval
    let hereMeas: PlaceEval
    let placeTrue: [PlaceEval]
    let placeMeas: [PlaceEval]
}

func run(_ t: Trial) -> Outcome {
    var rng = SplitMix64(seed: t.seed &* 7919)
    let volPct = Double(t.step) * 6.25
    var trueLeak10: [Double?] = Array(repeating: nil, count: NB)
    var leakAtMic = [Double](repeating: -Double.infinity, count: NB)
    if let ty = t.type {
        let est = Model.estimatedLeak(type: ty, fit: .normal, volumePct: volPct, loudness: .normal)
        for b in 0..<NB {
            let v = (est[b] ?? -Double.infinity) + t.dev[b]
            trueLeak10[b] = v
            leakAtMic[b] = v - musicAdj + 20 * log10(0.1 / t.micDist)
        }
    }
    let trueAmb = Model.bandsFromA(t.env.dBA, shape: t.env.shape)
    let mic = SimulatedMic(sampleRate: fs, ambientBank: ambientBank, leakBank: leakBank,
                           ambientDb: trueAmb, leakAtMicDb: leakAtMic, micNoiseDb: micNoiseDb,
                           calibration: K, modDepthDb: 2, seed: t.seed)
    let an = BandAnalyzer(sampleRate: fs)
    // 時刻（秒）: 0〜0.6 準備 / 0.6〜3.6 周りの音 / 3.6 テスト音開始 / 4.3〜7.8 テスト音
    let ambStart = 0.6, ambEnd = 3.6, toneStart = 3.6, latency = 0.25, toneWinStart = 4.3, toneWinEnd = 7.8
    if let b = t.burst {
        let center = b.inTone ? 4.3 + rng.uniform() * 2.5 : 0.6 + rng.uniform() * 2.2
        mic.burst = (start: Int(center * fs), length: Int(0.8 * fs), gainDb: b.gainDb, bands: [2, 3, 4])
    }
    var pAmb: [Double] = []
    var pTone: [Double] = []
    var phase = 0
    var k = 0
    while true {
        let tStart = Double(k * chunk) / fs
        if tStart >= toneWinEnd { break }
        mic.leakOn = tStart >= toneStart + latency
        let inAmb = tStart >= ambStart && tStart < ambEnd
        let inTone = tStart >= toneWinStart && tStart < toneWinEnd
        if inAmb && phase == 0 { an.reset(); phase = 1 }
        if !inAmb && phase == 1 { pAmb = an.robustPowers(); phase = 2 }
        if inTone && phase == 2 { an.reset(); phase = 3 }
        let x = mic.next(chunk)
        x.withUnsafeBufferPointer { an.process($0.baseAddress!, count: $0.count, accumulate: inAmb || inTone) }
        k += 1
    }
    pTone = an.robustPowers()
    let r = try! Model.computeMeasurement(ambient: pAmb, tone: pTone, valid: an.valid,
                                          volume: Double(t.step) / 16, calibration: K, routeName: "sim")
    let hereTrue = Model.evaluate(leak: trueLeak10, ambient: trueAmb, distance: Model.neighborDistance)
    let ub = r.detected.map { !$0 }
    let hereMeas = Model.evaluate(leak: r.leak10, ambient: Model.hereAmbient(r.ambientDb),
                                  distance: Model.neighborDistance, upperBound: ub)
    let placeTrue = Model.places.map { Model.evaluate(leak: trueLeak10, place: $0) }
    let placeMeas = Model.places.map { Model.evaluate(leak: r.leak10, place: $0, upperBound: ub) }
    return Outcome(trial: t, trueLeak10: trueLeak10, trueAmb: trueAmb, leakAtMic: leakAtMic, result: r,
                   hereTrue: hereTrue, hereMeas: hereMeas, placeTrue: placeTrue, placeMeas: placeMeas)
}

// ---- 試行を作る ----
var trials: [Trial] = []
var seed: UInt64 = 1000
var trng = SplitMix64(seed: 42)
for env in envs {
    for ty in types {
        for st in steps {
            for _ in 0..<2 {
                seed += 1
                let dist = 0.02 + trng.uniform() * 0.03
                let dev = (0..<NB).map { _ in (trng.uniform() * 2 - 1) * 3 }
                trials.append(Trial(env: env, type: ty, step: st, micDist: dist, dev: dev, burst: nil, seed: seed))
            }
        }
    }
}
let mainCount = trials.count
var noLeak: [Trial] = []
for env in envs {
    for _ in 0..<4 {
        seed += 1
        noLeak.append(Trial(env: env, type: nil, step: 10, micDist: 0.03, dev: Array(repeating: 0, count: NB), burst: nil, seed: seed))
    }
}
var bursts: [Trial] = []
for env in [envs[1], envs[2]] {
    for inTone in [true, false] {
        for _ in 0..<5 {
            seed += 1
            bursts.append(Trial(env: env, type: .inner, step: 8, micDist: 0.03, dev: Array(repeating: 0, count: NB),
                                burst: (inTone: inTone, gainDb: 10), seed: seed))
        }
    }
}

let t1 = Date()
let outs = trials.map(run)
let outsNo = noLeak.map(run)
let outsBurst = bursts.map(run)
print(String(format: "試行: 通常%d回 + 漏れなし%d回 + 突発音%d回 / 計算時間 %.1f秒", outs.count, outsNo.count, outsBurst.count, Date().timeIntervalSince(t1)))

// ---- 例：入力と出力を全部出す ----
print("")
print("=== 試行の例（入力と出力の全部） ===")
for idx in [0, 7 * 8 + 3, mainCount - 5] where idx < outs.count {
    let o = outs[idx]
    let t = o.trial
    print("■ 場所=\(t.env.name) 種類=\(t.type?.name ?? "なし") 音量=\(t.step)/16 マイク距離=\(String(format: "%.1f", t.micDist * 100))cm")
    print("  帯域         :   125   250   500    1k    2k    4k    8k   16k")
    print("  周りの音(真) : " + o.trueAmb.map { f1($0) }.joined(separator: " "))
    print("  周りの音(測) : " + o.result.ambientDb.map { f1($0) }.joined(separator: " "))
    print("  マイク位置の漏れ(真): " + o.leakAtMic.map { f1($0) }.joined(separator: " "))
    print("  10cmの漏れ(真) : " + o.trueLeak10.map { f1($0) }.joined(separator: " "))
    print("  10cmの漏れ(測) : " + o.result.leak10.map { f1($0) }.joined(separator: " "))
    print("  検出           : " + o.result.detected.map { $0 ? "  ○  " : "  ×  " }.joined(separator: " "))
    print("  測った場所の判定: 真=\(Model.levelNames[o.hereTrue.level]) / 実測=\(Model.levelNames[o.hereMeas.level])\(o.hereMeas.uncertain ? "（これ以下）" : "")")
    for (i, p) in Model.places.enumerated() {
        print("    \(p.name): 真=\(Model.levelNames[o.placeTrue[i].level]) / 実測=\(Model.levelNames[o.placeMeas[i].level])\(o.placeMeas[i].uncertain ? "（これ以下）" : "")")
    }
}

// ---- 1. 漏れ量の誤差 ----
print("")
print("=== 1. 漏れ量の誤差（検出できた帯域だけ。実測 − 真の値） ===")
func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "n=0" }
    let m = xs.reduce(0, +) / Double(xs.count)
    let sd = (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)).squareRoot()
    let mx = xs.map { abs($0) }.max() ?? 0
    let within3 = xs.filter { abs($0) <= 3 }.count
    return String(format: "n=%4d 平均%+5.1f 標準偏差%4.1f 最大%4.1f ±3dB以内%5.1f%%", xs.count, m, sd, mx, 100 * Double(within3) / Double(xs.count))
}
func errors(_ os: [Outcome]) -> [Double] {
    var e: [Double] = []
    for o in os {
        for b in 1..<NB where o.result.detected[b] {
            if let m = o.result.leak10[b], let tv = o.trueLeak10[b] { e.append(m - tv) }
        }
    }
    return e
}
print("  全体             : " + stats(errors(outs)))
for env in envs { print("  \(env.name)".padding(toLength: 20, withPad: "　", startingAt: 0) + ": " + stats(errors(outs.filter { $0.trial.env.name == env.name }))) }
for (lo, hi) in [(0.02, 0.025), (0.025, 0.035), (0.035, 0.045), (0.045, 0.0501)] {
    let sel = outs.filter { $0.trial.micDist >= lo && $0.trial.micDist < hi }
    print(String(format: "  マイク距離%.1f〜%.1fcm: ", lo * 100, hi * 100) + stats(errors(sel)))
}

// ---- 2. 検出率 ----
print("")
print("=== 2. 漏れを検出できた割合（マイク位置での 漏れ − 周りの音 の差ごと） ===")
let buckets: [(String, Double, Double)] = [("−10dB未満", -100, -10), ("−10〜−5dB", -10, -5), ("−5〜0dB", -5, 0), ("0〜+5dB", 0, 5), ("+5〜+10dB", 5, 10), ("+10dB以上", 10, 200)]
for (name, lo, hi) in buckets {
    var n = 0, d = 0
    for o in outs {
        for b in 1..<NB {
            let snr = o.leakAtMic[b] - o.trueAmb[b]
            if snr >= lo && snr < hi { n += 1; if o.result.detected[b] { d += 1 } }
        }
    }
    print("  \(name): 検出 \(d)/\(n) = \(pct(d, n))")
}

// ---- 3. 判定の一致 ----
func agreement(_ pairs: [(Int, Int, Bool)]) -> String {
    let n = pairs.count
    let exact = pairs.filter { $0.0 == $0.1 }.count
    let near = pairs.filter { abs($0.0 - $0.1) <= 1 }.count
    let lenient = pairs.filter { $0.0 >= 2 && $0.1 <= 1 }.count
    let strict = pairs.filter { $0.0 <= 1 && $0.1 >= 3 }
    let strictMarked = strict.filter { $0.2 }.count
    return "n=\(n) 一致\(pct(exact, n)) ±1段階以内\(pct(near, n)) 甘く出た(真は気づかれるのに実測は大丈夫)\(pct(lenient, n)) 厳しく出た\(pct(strict.count, n))（うち「これ以下」の印つき \(strictMarked)/\(strict.count)）"
}
print("")
print("=== 3. 判定の一致（真の値で判定した結果と、実測値で判定した結果） ===")
print("  測った場所で隣の席: " + agreement(outs.map { ($0.hereTrue.level, $0.hereMeas.level, $0.hereMeas.uncertain) }))
for env in envs {
    let sel = outs.filter { $0.trial.env.name == env.name }
    print("    \(env.name)で測定: " + agreement(sel.map { ($0.hereTrue.level, $0.hereMeas.level, $0.hereMeas.uncertain) }))
}
print("  場面の物差し（8場面）:")
for env in envs {
    let sel = outs.filter { $0.trial.env.name == env.name }
    var pairs: [(Int, Int, Bool)] = []
    for o in sel { for i in 0..<Model.places.count { pairs.append((o.placeTrue[i].level, o.placeMeas[i].level, o.placeMeas[i].uncertain)) } }
    print("    \(env.name)で測定: " + agreement(pairs))
}

// ---- 4. 漏れがないとき ----
print("")
print("=== 4. イヤホンから何も漏れていないとき（誤って検出しないか） ===")
for env in envs {
    let sel = outsNo.filter { $0.trial.env.name == env.name }
    let det = sel.map { $0.result.detectedCount }
    let here = sel.map { Model.levelNames[$0.hereMeas.level] }
    print("  \(env.name): 検出した帯域数 \(det) / 測った場所の判定 \(here)")
}

// ---- 5. 突発音 ----
print("")
print("=== 5. 測定中に話し声やアナウンス（500Hz〜2kHzが10dB大きくなる、0.8秒）が入ったとき ===")
for env in [envs[1], envs[2]] {
    for inTone in [true, false] {
        let sel = outsBurst.filter { $0.trial.env.name == env.name && $0.trial.burst?.inTone == inTone }
        var e: [Double] = []
        for o in sel { for b in [2, 3, 4] where o.result.detected[b] { if let m = o.result.leak10[b], let tv = o.trueLeak10[b] { e.append(m - tv) } } }
        let lv = sel.map { "\(Model.levelNames[$0.hereTrue.level])→\(Model.levelNames[$0.hereMeas.level])" }
        print("  \(env.name)・\(inTone ? "テスト音の間" : "周りの音の間"): 500Hz〜2kHzの誤差 " + stats(e))
        print("      測った場所の判定（真→実測）: \(lv)")
    }
}
