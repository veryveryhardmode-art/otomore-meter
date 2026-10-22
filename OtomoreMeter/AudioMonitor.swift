import AVFoundation
import UIKit

/// iPhoneの音量と、いま音が出ているイヤホンを監視する
final class AudioMonitor: ObservableObject {
    @Published private(set) var volume: Double = 0.5
    @Published private(set) var routeName: String = ""
    @Published private(set) var routeKind: RouteKind = .speaker
    @Published private(set) var guessedType: EarType?

    /// 実測中は音声セッションを触らない
    var isPaused = false

    private let session = AVAudioSession.sharedInstance()
    private var volumeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    init() {
        activate()
        volumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] s, _ in
            let v = Double(s.outputVolume)
            DispatchQueue.main.async {
                self?.volume = v
            }
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateRoute()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activate()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activate()
        })
        updateRoute()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// ほかのアプリの音楽を止めない設定で音声セッションを有効にする（音量の変化を受け取るため）
    func activate() {
        guard !isPaused else { return }
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 失敗しても、読み取れる範囲で続ける
        }
        volume = Double(session.outputVolume)
        updateRoute()
    }

    func updateRoute() {
        guard let out = session.currentRoute.outputs.first else {
            routeName = ""
            routeKind = .speaker
            guessedType = nil
            return
        }
        let kind: RouteKind
        switch out.portType {
        case .headphones, .usbAudio:
            kind = .wired
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            kind = .bluetooth
        case .builtInSpeaker, .builtInReceiver:
            kind = .speaker
        default:
            kind = .other
        }
        routeKind = kind
        routeName = out.portName
        guessedType = kind.isHeadphones ? EarphoneCatalog.guess(name: out.portName) : nil
    }
}
