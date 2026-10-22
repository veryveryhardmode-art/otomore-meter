import Foundation

/// 再現できる乱数（検証用）
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// オクターブ帯域（125Hz〜8kHz）ごとに分けたノイズ。各帯域の平均二乗は1にそろえてある
final class BandSignalBank {
    let length: Int
    private(set) var bands: [[Float]]

    init(sampleRate fs: Double, seconds: Double, toneCount: Int, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let n = Int((fs * seconds).rounded())
        length = n
        let df = 1 / seconds
        var perBand: [[Double]] = Array(repeating: [], count: Model.bandFreqs.count)
        let fLow = 63.0
        let fHigh = 18000.0
        var lastK = -1
        for i in 0..<toneCount {
            let f = fLow * pow(fHigh / fLow, Double(i) / Double(toneCount - 1))
            let k = Int((f / df).rounded())
            if k == lastK { continue }
            lastK = k
            let fk = Double(k) * df
            let b = max(0, min(Model.bandFreqs.count - 1, Int(log2(fk / 125).rounded())))
            perBand[b].append(fk)
        }
        var out: [[Float]] = []
        for b in 0..<perBand.count {
            var acc = [Double](repeating: 0, count: n)
            acc.withUnsafeMutableBufferPointer { buf in
                for f in perBand[b] {
                    let w = 2 * Double.pi * f / fs
                    let ph = rng.uniform() * 2 * Double.pi
                    var c = cos(ph)
                    var s = sin(ph)
                    let cw = cos(w)
                    let sw = sin(w)
                    for j in 0..<n {
                        buf[j] += s
                        let nc = c * cw - s * sw
                        s = s * cw + c * sw
                        c = nc
                    }
                }
            }
            var ss = 0.0
            for v in acc { ss += v * v }
            let g = ss > 0 ? 1 / (ss / Double(n)).squareRoot() : 0
            out.append(acc.map { Float($0 * g) })
        }
        bands = out
    }
}

/// iPhoneのマイクに入る音を合成する：周りの騒音（ゆっくり揺らぐ）＋イヤホンから漏れたテスト音＋マイク自身の雑音
final class SimulatedMic {
    let sampleRate: Double
    private let ambientBank: BandSignalBank
    private let leakBank: BandSignalBank
    private var rng: SplitMix64
    private var ambientPower: [Double]
    private var leakPower: [Double]
    private let noiseAmp: Double
    private let modDepthDb: Double
    private var modFreq: [Double] = []
    private var modPhase: [Double] = []
    private(set) var position = 0
    /// テスト音が鳴っているか（イヤホン側で鳴り始めた時刻から遅れて入る）
    var leakOn = false
    /// 一時的な大きな音（アナウンスや話し声）：開始サンプル、長さ、大きさ(dB)、対象の帯域
    var burst: (start: Int, length: Int, gainDb: Double, bands: [Int])?

    /// ambientDb / leakAtMicDb は dB SPL（帯域ごと）。calibration は dBFS → dB SPL の換算値
    init(sampleRate fs: Double, ambientBank: BandSignalBank, leakBank: BandSignalBank,
         ambientDb: [Double], leakAtMicDb: [Double], micNoiseDb: Double,
         calibration k: Double, modDepthDb: Double, seed: UInt64) {
        sampleRate = fs
        self.ambientBank = ambientBank
        self.leakBank = leakBank
        rng = SplitMix64(seed: seed)
        ambientPower = ambientDb.map { pow(10, ($0 - k) / 10) }
        leakPower = leakAtMicDb.map { $0.isFinite ? pow(10, ($0 - k) / 10) : 0 }
        noiseAmp = pow(10, (micNoiseDb - k) / 20)
        self.modDepthDb = modDepthDb
        for _ in 0..<Model.bandFreqs.count {
            modFreq.append(0.15 + rng.uniform() * 0.8)
            modPhase.append(rng.uniform() * 2 * Double.pi)
        }
        position = Int(rng.uniform() * Double(ambientBank.length))
    }

    func next(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let nb = Model.bandFreqs.count
        let t0 = Double(position) / sampleRate
        // 帯域ごとの振幅（このかたまりの中では一定とみなす）
        var ampA = [Double](repeating: 0, count: nb)
        var ampL = [Double](repeating: 0, count: nb)
        for b in 0..<nb {
            let m = modDepthDb * sin(2 * Double.pi * modFreq[b] * t0 + modPhase[b])
            var p = ambientPower[b] * pow(10, m / 10)
            if let bu = burst, bu.bands.contains(b), position >= bu.start, position < bu.start + bu.length {
                p *= pow(10, bu.gainDb / 10)
            }
            ampA[b] = p.squareRoot()
            ampL[b] = leakOn ? leakPower[b].squareRoot() : 0
        }
        let la = ambientBank.length
        let ll = leakBank.length
        let A = ambientBank.bands
        let L = leakBank.bands
        for i in 0..<count {
            let ia = (position + i) % la
            let il = (position + i) % ll
            var v = 0.0
            for b in 0..<nb {
                v += ampA[b] * Double(A[b][ia]) + ampL[b] * Double(L[b][il])
            }
            v += noiseAmp * rng.gaussian()
            out[i] = Float(v)
        }
        position += count
        return out
    }
}
