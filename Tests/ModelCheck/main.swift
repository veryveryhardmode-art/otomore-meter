import Foundation

// Web版と同じ入力で、Swiftに移した計算が同じ値を出すかを確かめる

func f1(_ v: Double?) -> String {
    guard let v = v, v.isFinite else { return "—" }
    return String(format: "%.1f", v)
}

func s1(_ v: Double) -> String {
    guard v.isFinite else { return "—" }
    return String(format: "%+.1f", v)
}

func show(_ title: String, type: EarType, fit: Fit, vol: Double, loud: Loudness) {
    let leak = Model.estimatedLeak(type: type, fit: fit, volumePct: vol, loudness: loud)
    print("■ \(title)  入力: type=\(type.rawValue) fit=\(fit.rawValue) vol=\(Int(vol))% loudness=\(loud.rawValue)  耳に届く音=\(f1(Model.earLevel(volumePct: vol, loudness: loud)))dBA")
    print("  漏れ(10cm, 125〜16k): " + leak.map { f1($0) }.joined(separator: " / "))
    for p in Model.places {
        let ev = Model.evaluate(leak: leak, place: p)
        let safe = Model.safeVolumePct(current: vol, worstMargin: ev.worstMargin)
        let band = ev.worstBand >= 0 ? Model.bandLabels[ev.worstBand] : "-"
        let ear = Model.safeEarDb(currentEar: Model.earLevel(volumePct: vol, loudness: loud), worstMargin: ev.worstMargin)
        print("  \(p.name) 差\(s1(ev.worstMargin))dB(\(band)) → \(Model.levelNames[ev.level]) / セーフ上限 \(Int(safe))%（\(Model.steps(fromPct: safe))/16）/ 耳で\(ear >= Model.maxEar ? "何dBでもOK" : "約" + f1(ear) + "dBまで")")
    }
}

print("=== 1. 推定モデル（Web版と同じ4ケース） ===")
show("インナーイヤー 70%", type: .inner, fit: .normal, vol: 70, loud: .normal)
show("カナル型(ふつう) 70%", type: .canal, fit: .normal, vol: 70, loud: .normal)
show("カナル型(ぴったり) 100%", type: .canal, fit: .tight, vol: 100, loud: .normal)
show("オープンイヤー 50%", type: .open, fit: .normal, vol: 50, loud: .normal)

print("")
print("=== 2. 実測計算の逆算テスト ===")
let K = 120.0
let trueLeak = Model.estimatedLeak(type: .inner, fit: .normal, volumePct: 70, loudness: .normal)
let amb = Model.bandsFromA(40, shape: Model.shapeQuiet)
let distAdj = 20 * log10(Model.micDistance / 0.1)
let musicAdj = Model.musicDbfs - Model.testToneDbfs
func powerOf(_ db: Double) -> Double { pow(10, (db - K) / 10) }
var ambP: [Double] = []
var toneP: [Double] = []
for i in 0..<Model.bandFreqs.count {
    let leakAtMic = (trueLeak[i] ?? 0) - distAdj - musicAdj
    ambP.append(powerOf(amb[i]))
    toneP.append(powerOf(amb[i]) + powerOf(leakAtMic))
}
print("入力: 周りの音=静かな部屋40dB, 真の漏れ=インナーイヤー70%相当, マイク距離\(Int(Model.micDistance * 100))cm, 感度K=\(Int(K))")
do {
    let r = try Model.computeMeasurement(ambient: ambP, tone: toneP, valid: Array(repeating: true, count: Model.bandFreqs.count),
                                         volume: 0.7, calibration: K, routeName: "test")
    for i in 1..<Model.bandFreqs.count {
        print("  \(Model.bandLabels[i])Hz: 真の漏れ\(f1(trueLeak[i])) → 計算\(f1(r.leak10[i]))  周りの音 真\(f1(amb[i])) → 計算\(f1(r.ambientDb[i]))  検出=\(r.detected[i])")
    }
    print("  測った場所の周りの音(A特性): \(f1(r.ambientA))dB")
} catch {
    print("  エラー: \(error)")
}

print("")
print("=== 3. テスト音とバンド分析 ===")
let t0 = Date()
let fs = 48000.0
let samples = ToneGenerator.samples(sampleRate: fs, seconds: 2, rmsDbfs: Model.testToneDbfs)
let genTime = Date().timeIntervalSince(t0)
var ss = 0.0
var pk: Float = 0
for v in samples {
    ss += Double(v) * Double(v)
    pk = max(pk, abs(v))
}
print("  生成: \(samples.count)サンプル, \(String(format: "%.2f", genTime))秒, RMS \(f1(10 * log10(ss / Double(samples.count))))dBFS(目標 \(f1(Model.testToneDbfs))), ピーク \(f1(20 * log10(Double(pk))))dBFS")
print("  つなぎ目: 先頭 \(String(format: "%.4f", samples.first ?? 0)) / 末尾 \(String(format: "%.4f", samples.last ?? 0))")
let an = BandAnalyzer(sampleRate: fs)
samples.withUnsafeBufferPointer { an.process($0.baseAddress!, count: $0.count, accumulate: false) }
samples.withUnsafeBufferPointer { an.process($0.baseAddress!, count: $0.count, accumulate: true) }
let bands = an.meanPowers().map { 10 * log10($0) }
for i in 0..<Model.bandFreqs.count {
    print("  \(Model.bandLabels[i])Hz: 分析 \(s1(bands[i] - bands[0]))dB / 設計 \(s1(Model.music[i] - Model.music[0]))dB")
}

print("")
print("=== 4. イヤホン名からの種類判定 ===")
let names = ["宏伸のAirPods Pro", "AirPods", "AirPods Max", "AirPods 4", "EarPods", "WF-1000XM5", "WH-1000XM5",
             "LinkBuds S", "LinkBuds", "Shokz OpenRun Pro", "Shokz OpenFit", "Beats Solo Buds", "Beats Solo 4",
             "Beats Studio Pro", "Galaxy Buds2 Pro", "Bose QuietComfort Ultra Earbuds", "Bose QuietComfort Ultra Headphones",
             "ambie sound earcuffs", "Headphones", "ヘッドフォン"]
for n in names {
    print("  \(n) → \(EarphoneCatalog.guess(name: n)?.name ?? "判定できず（手動で選ぶ）")")
}

print("")
print("=== 5. ヘルスケアのヘッドフォン音量のまとめ ===")
let exposureCases: [(String, [(db: Double, dur: Double)])] = [
    ("同じ音量だけ", [(db: 70, dur: 3600)]),
    ("ふだん65dBで1時間、たまに85dBで10分", [(db: 65, dur: 3600), (db: 85, dur: 600)]),
    ("UIテストと同じ", [(db: 62, dur: 3600), (db: 68, dur: 5400), (db: 74, dur: 1800), (db: 82, dur: 600)]),
    ("記録なし", [])
]
for (name, vals) in exposureCases {
    let input = vals.map { "\(Int($0.db))dB×\(Int($0.dur))秒" }.joined(separator: ", ")
    if let s = Model.exposureStats(vals) {
        print("  \(name)  入力: [\(input)] → 平均(Leq) \(f1(s.average))dB / 上位10% \(f1(s.p90))dB / 最大 \(f1(s.maximum))dB / \(String(format: "%.2f", s.hours))時間")
    } else {
        print("  \(name)  入力: [\(input)] → 記録なし")
    }
}
