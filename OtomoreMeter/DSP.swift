import AVFoundation

/// 2次のバンドパスフィルタ（RBJ、ピーク0dB）
struct Biquad {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var z1: Double = 0
    var z2: Double = 0

    static func bandpass(center fc: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let w0 = 2 * Double.pi * fc / fs
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    /// 周波数fでのパワー利得 |H|²
    func powerGain(at f: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        let nr = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let ni = -(b1 * sin(w) + b2 * sin(2 * w))
        let dr = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let di = -(a1 * sin(w) + a2 * sin(2 * w))
        return (nr * nr + ni * ni) / (dr * dr + di * di)
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// マイクの音をオクターブ帯域（125Hz〜16kHz）ごとのパワーに分ける
final class BandAnalyzer {
    private var stages: [[Biquad]]
    private(set) var sums: [Double]
    private(set) var count = 0
    /// かたまり（約85ms）ごとのパワー。突発音に強い中央値を出すために残す
    private(set) var chunkPowers: [[Double]]
    let valid: [Bool]
    /// フィルタの読み取りの補正（帯域内で平らな音を、その帯域のパワーどおりに読むための倍率）。
    /// 高い帯域ほどフィルタの幅が狭くなって小さく読むので、その分を戻す（16kHz帯は約3.5dB）
    let correction: [Double]
    /// 帯域の上限（マイクとテスト音で扱う上限）
    static let topFrequency = 18000.0

    init(sampleRate fs: Double) {
        var st: [[Biquad]] = []
        var ok: [Bool] = []
        var corr: [Double] = []
        for fc in Model.bandFreqs {
            let usable = fc * 1.35 < fs / 2
            let center = usable ? fc : fs / 4
            let bq = Biquad.bandpass(center: center, q: 1.414, sampleRate: fs)
            st.append([bq, bq])
            ok.append(usable)
            // 帯域内（fc/√2〜fc√2、ただし上限まで）で対数的に平らな音を通したときの平均利得（2段なので2乗）
            let lo = fc / 2.0.squareRoot()
            let hi = min(fc * 2.0.squareRoot(), min(BandAnalyzer.topFrequency, fs / 2 * 0.98))
            var g = 0.0
            let n = 400
            if usable && hi > lo {
                for k in 0..<n {
                    let f = lo * pow(hi / lo, (Double(k) + 0.5) / Double(n))
                    let p = bq.powerGain(at: f, sampleRate: fs)
                    g += p * p
                }
                g /= Double(n)
            }
            corr.append(g > 0 ? 1 / g : 1)
        }
        stages = st
        valid = ok
        correction = corr
        sums = Array(repeating: 0, count: Model.bandFreqs.count)
        chunkPowers = Array(repeating: [], count: Model.bandFreqs.count)
    }

    func reset() {
        for i in 0..<sums.count {
            sums[i] = 0
            chunkPowers[i].removeAll(keepingCapacity: true)
        }
        count = 0
    }

    func process(_ samples: UnsafePointer<Float>, count n: Int, accumulate: Bool) {
        guard n > 0 else { return }
        for b in 0..<stages.count {
            var s1 = stages[b][0]
            var s2 = stages[b][1]
            var acc = 0.0
            for i in 0..<n {
                let y = s2.step(s1.step(Double(samples[i])))
                acc += y * y
            }
            stages[b][0] = s1
            stages[b][1] = s2
            if accumulate {
                sums[b] += acc
                chunkPowers[b].append(acc / Double(n))
            }
        }
        if accumulate { count += n }
    }

    func meanPowers() -> [Double] {
        let c = Double(count)
        return sums.enumerated().map { count > 0 ? $0.element / c * correction[$0.offset] : 0 }
    }

    /// かたまりごとのパワーの中央値（話し声やアナウンスが一瞬入っても引っぱられにくい）
    func robustPowers() -> [Double] {
        chunkPowers.enumerated().map { b, arr in
            guard !arr.isEmpty else { return 0 }
            let s = arr.sorted()
            let m = s.count / 2
            let med = s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
            return med * correction[b]
        }
    }
}

/// 一般的な曲と同じ帯域バランスのテスト音（ループしてもつなぎ目が出ない長さで作る）
enum ToneGenerator {
    static func musicShape(at f: Double) -> Double {
        let x = log2(f / 125)
        let m = Model.music
        if x <= 0 { return m[0] }
        let top = Double(m.count - 1)
        if x >= top { return m[m.count - 1] - (x - top) * 6 }
        let i = Int(x.rounded(.down))
        let t = x - Double(i)
        return m[i] + (m[i + 1] - m[i]) * t
    }

    /// 生のサンプル列（フルスケール±1）
    static func samples(sampleRate fs: Double, seconds: Double, rmsDbfs: Double) -> [Float] {
        let n = Int((fs * seconds).rounded())
        guard n > 0 else { return [] }
        let df = 1 / seconds
        var freqs: [Double] = []
        let toneCount = 400
        let fLow = 63.0
        let fHigh = BandAnalyzer.topFrequency
        var lastK = -1
        for i in 0..<toneCount {
            let f = fLow * pow(fHigh / fLow, Double(i) / Double(toneCount - 1))
            let k = Int((f / df).rounded())
            if k != lastK {
                freqs.append(Double(k) * df)
                lastK = k
            }
        }
        var acc = [Double](repeating: 0, count: n)
        acc.withUnsafeMutableBufferPointer { buf in
            for f in freqs {
                let amp = pow(10, musicShape(at: f) / 20)
                let w = 2 * Double.pi * f / fs
                let ph = Double.random(in: 0..<(2 * Double.pi))
                var c = cos(ph)
                var s = sin(ph)
                let cw = cos(w)
                let sw = sin(w)
                for j in 0..<n {
                    buf[j] += amp * s
                    let nc = c * cw - s * sw
                    s = s * cw + c * sw
                    c = nc
                }
            }
        }
        var ss = 0.0
        var peak = 0.0
        for v in acc {
            ss += v * v
            peak = max(peak, abs(v))
        }
        let rms = (ss / Double(n)).squareRoot()
        guard rms > 0 else { return [] }
        var g = pow(10, rmsDbfs / 20) / rms
        if peak * g > 0.95 { g = 0.95 / peak }
        return acc.map { Float($0 * g) }
    }

    static func make(sampleRate fs: Double = 48000, seconds: Double = 2, rmsDbfs: Double = Model.testToneDbfs) -> AVAudioPCMBuffer? {
        let data = samples(sampleRate: fs, seconds: seconds, rmsDbfs: rmsDbfs)
        guard !data.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(data.count)
        for j in 0..<data.count { out[j] = data[j] }
        return buffer
    }
}
