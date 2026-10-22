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

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// マイクの音をオクターブ帯域（125Hz〜8kHz）ごとのパワーに分ける
final class BandAnalyzer {
    private var stages: [[Biquad]]
    private(set) var sums: [Double]
    private(set) var count = 0
    /// かたまり（約85ms）ごとのパワー。突発音に強い中央値を出すために残す
    private(set) var chunkPowers: [[Double]]
    let valid: [Bool]

    init(sampleRate fs: Double) {
        var st: [[Biquad]] = []
        var ok: [Bool] = []
        for fc in Model.bandFreqs {
            let usable = fc * 1.5 < fs / 2
            let center = usable ? fc : fs / 4
            let bq = Biquad.bandpass(center: center, q: 1.414, sampleRate: fs)
            st.append([bq, bq])
            ok.append(usable)
        }
        stages = st
        valid = ok
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
        return sums.map { count > 0 ? $0 / c : 0 }
    }

    /// かたまりごとのパワーの中央値（話し声やアナウンスが一瞬入っても引っぱられにくい）
    func robustPowers() -> [Double] {
        chunkPowers.map { arr in
            guard !arr.isEmpty else { return 0 }
            let s = arr.sorted()
            let m = s.count / 2
            return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
        }
    }
}

/// 一般的な曲と同じ帯域バランスのテスト音（ループしてもつなぎ目が出ない長さで作る）
enum ToneGenerator {
    static func musicShape(at f: Double) -> Double {
        let x = log2(f / 125)
        let m = Model.music
        if x <= 0 { return m[0] }
        if x >= 6 { return m[6] - (x - 6) * 6 }
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
        let fHigh = 14000.0
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
