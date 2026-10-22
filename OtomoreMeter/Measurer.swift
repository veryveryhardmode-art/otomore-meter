import AVFoundation
import UIKit

enum MeasurePhase: Equatable {
    case idle
    case countdown(Int)
    case ambient
    case tone
    case done
    case failed(String)
}

/// iPhone本体のマイクで、周りの音とテスト音の漏れを測る
final class Measurer: ObservableObject {
    @Published var phase: MeasurePhase = .idle
    @Published var progress: Double = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var analyzer: BandAnalyzer?
    private let lock = NSLock()
    private var collecting = false
    private var cancelled = false
    private var tone: AVAudioPCMBuffer?

    init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = ToneGenerator.make()
            DispatchQueue.main.async {
                if self?.tone == nil { self?.tone = t }
            }
        }
    }

    var isRunning: Bool {
        switch phase {
        case .countdown(_), .ambient, .tone: return true
        default: return false
        }
    }

    func cancel() {
        cancelled = true
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    @MainActor
    func run(calibration: Double, routeName: String, restore: @escaping () -> Void) async -> MeasureResult? {
        if isRunning { return nil }
        cancelled = false
        progress = 0
        phase = .idle
        let mock = TestHooks.mockMic
        let granted = mock ? true : await Measurer.requestPermission()
        guard granted else {
            restore()
            phase = .failed("マイクの使用が許可されていません。設定アプリ →「音漏れメーター」→ マイク をオンにしてください。")
            return nil
        }
        do {
            let currentVolume = TestHooks.mockVolume ?? Double(AVAudioSession.sharedInstance().outputVolume)
            if currentVolume < 0.01 { throw MeasureError.zeroVolume }
            if !mock {
                if tone == nil { tone = ToneGenerator.make() }
                guard tone != nil else { throw MeasureError.toneNotReady }
            }

            let tick = UIImpactFeedbackGenerator(style: .medium)
            tick.prepare()
            for n in stride(from: 3, through: 1, by: -1) {
                phase = .countdown(n)
                tick.impactOccurred()
                try await pause(1.0)
            }

            if mock {
                startSimulatedMic(volume: currentVolume, routeName: routeName)
                try await pause(0.6)
            } else {
                try startEngine()
                try await pause(0.6)
                let route = AVAudioSession.sharedInstance().currentRoute
                guard Measurer.outputIsHeadphones(AVAudioSession.sharedInstance()) else { throw MeasureError.noHeadphoneOutput }
                guard route.inputs.first?.portType == .builtInMic else { throw MeasureError.notBuiltInMic }
            }

            phase = .ambient
            let ambient = try await collect(seconds: 3.0, from: 0, to: 0.45)

            phase = .tone
            playTone()
            try await pause(0.7)
            let volume = TestHooks.mockVolume ?? Double(AVAudioSession.sharedInstance().outputVolume)
            let tonePowers = try await collect(seconds: 3.5, from: 0.5, to: 1.0)
            let valid = analyzerValid()

            stopEngine()
            restore()

            let result = try Model.computeMeasurement(ambient: ambient, tone: tonePowers, valid: valid,
                                                      volume: volume, calibration: calibration,
                                                      routeName: routeName)
            phase = .done
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return result
        } catch {
            stopEngine()
            restore()
            if cancelled {
                phase = .idle
            } else if let e = error as? LocalizedError, let msg = e.errorDescription {
                phase = .failed(msg)
            } else {
                phase = .failed("測定できませんでした（\(error.localizedDescription)）")
            }
            return nil
        }
    }

    // MARK: - 手順

    @MainActor
    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if cancelled { throw MeasureError.cancelled }
    }

    @MainActor
    private func collect(seconds: Double, from p0: Double, to p1: Double) async throws -> [Double] {
        lock.lock()
        analyzer?.reset()
        collecting = true
        lock.unlock()
        let steps = max(1, Int((seconds / 0.1).rounded()))
        for i in 0..<steps {
            try await pause(0.1)
            progress = p0 + (p1 - p0) * Double(i + 1) / Double(steps)
        }
        lock.lock()
        collecting = false
        let powers = analyzer?.robustPowers() ?? []
        let n = analyzer?.count ?? 0
        lock.unlock()
        if n == 0 { throw MeasureError.noInput }
        return powers
    }

    private func analyzerValid() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return analyzer?.valid ?? []
    }

    private static func outputIsHeadphones(_ s: AVAudioSession) -> Bool {
        guard let o = s.currentRoute.outputs.first else { return false }
        let ok: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .usbAudio]
        return ok.contains(o.portType)
    }

    @MainActor
    private func startEngine() throws {
        let s = AVAudioSession.sharedInstance()
        // HFP（通話モード）を許可しないことで、AirPodsは高音質のまま、入力はiPhoneのマイクになる
        try s.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP])
        try s.setActive(true)
        if !Measurer.outputIsHeadphones(s) {
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try s.setActive(true)
        }

        guard let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw MeasureError.noBuiltInMic
        }
        try s.setPreferredInput(mic)
        if let bottom = mic.dataSources?.first(where: { $0.orientation == .bottom }) {
            try? mic.setPreferredDataSource(bottom)
            if let patterns = bottom.supportedPolarPatterns, patterns.contains(.omnidirectional) {
                try? bottom.setPreferredPolarPattern(.omnidirectional)
            }
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeasureError.noInput }

        let a = BandAnalyzer(sampleRate: format.sampleRate)
        lock.lock()
        analyzer = a
        collecting = false
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        let p = AVAudioPlayerNode()
        e.attach(p)
        let toneFormat = tone?.format ?? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        e.connect(p, to: e.mainMixerNode, format: toneFormat)
        e.prepare()
        try e.start()
        engine = e
        player = p
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        lock.lock()
        analyzer?.process(data[0], count: n, accumulate: collecting)
        lock.unlock()
    }

    // MARK: - シミュレーター用（合成した録音をマイクの代わりに流す）

    private var simTimer: DispatchSourceTimer?
    private var sim: SimulatedMic?
    private let simQueue = DispatchQueue(label: "otomore.simulated-mic")

    @MainActor
    private func startSimulatedMic(volume: Double, routeName: String) {
        let fs = 48000.0
        let a = BandAnalyzer(sampleRate: fs)
        lock.lock()
        analyzer = a
        collecting = false
        lock.unlock()
        let type = TestHooks.mockTrueType ?? EarphoneCatalog.guess(name: routeName) ?? .canal
        let est = Model.estimatedLeak(type: type, fit: .normal, volumePct: volume * 100, loudness: .normal)
        let musicAdj = Model.musicDbfs - Model.testToneDbfs
        let leakAtMic = est.map { ($0 ?? -Double.infinity) - musicAdj + 20 * log10(0.1 / Model.micDistance) }
        let scene = TestHooks.mockScene
        let amb = Model.bandsFromA(scene.dBA, shape: scene.shape)
        let ambientBank = BandSignalBank(sampleRate: fs, seconds: 3, toneCount: 240, seed: 5)
        let leakBank = BandSignalBank(sampleRate: fs, seconds: 1, toneCount: 240, seed: 6)
        let mic = SimulatedMic(sampleRate: fs, ambientBank: ambientBank, leakBank: leakBank,
                               ambientDb: amb, leakAtMicDb: leakAtMic, micNoiseDb: 32,
                               calibration: Model.micCalibration, modDepthDb: 2, seed: 7)
        sim = mic
        let timer = DispatchSource.makeTimerSource(queue: simQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(85))
        timer.setEventHandler { [weak self] in
            guard let self = self, let m = self.sim else { return }
            let x = m.next(4096)
            x.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                self.lock.lock()
                self.analyzer?.process(base, count: p.count, accumulate: self.collecting)
                self.lock.unlock()
            }
        }
        timer.resume()
        simTimer = timer
    }

    @MainActor
    private func playTone() {
        if TestHooks.mockMic {
            // Bluetoothの遅れぶん待ってから「漏れ」を入れる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.sim?.leakOn = true
            }
            return
        }
        guard let p = player, let t = tone else { return }
        p.volume = 1
        p.scheduleBuffer(t, at: nil, options: .loops, completionHandler: nil)
        p.play()
    }

    @MainActor
    private func stopEngine() {
        simTimer?.cancel()
        simTimer = nil
        sim = nil
        player?.stop()
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        player = nil
        lock.lock()
        collecting = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
