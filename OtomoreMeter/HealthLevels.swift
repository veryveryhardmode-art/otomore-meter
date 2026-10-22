import Foundation
import HealthKit

/// ヘルスケアの「ヘッドフォン音量」（耳に届いた音の大きさ）を読み、ふだんの音量をまとめる
final class HealthLevels: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case unavailable(String)
        case loaded
    }

    @Published var state: State = .idle
    @Published private(set) var average: Double = 0
    @Published private(set) var p90: Double = 0
    @Published private(set) var maximum: Double = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var totalHours: Double = 0

    private let store: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil

    init() {
        if let mock = TestHooks.mockHealth {
            apply(mock)
            state = .loaded
        }
    }

    func load() {
        if let mock = TestHooks.mockHealth {
            apply(mock)
            state = .loaded
            return
        }
        guard let store = store, let type = HKObjectType.quantityType(forIdentifier: .headphoneAudioExposure) else {
            state = .unavailable("この端末ではヘルスケアを使えません。")
            return
        }
        state = .loading
        let read: Set<HKObjectType> = [type]
        store.requestAuthorization(toShare: nil, read: read) { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.state = .unavailable("ヘルスケアを使えませんでした。このインストール方法では許可がないのかもしれません（\(error.localizedDescription)）。")
                }
                return
            }
            self?.query(store: store, type: type)
        }
    }

    private func query(store: HKHealthStore, type: HKQuantityType) {
        let start = Date().addingTimeInterval(-30 * 24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                              sortDescriptors: nil) { [weak self] _, samples, error in
            let unit = HKUnit.decibelAWeightedSoundPressureLevel()
            var vals: [(db: Double, dur: Double)] = []
            for s in (samples as? [HKQuantitySample]) ?? [] {
                let db = s.quantity.doubleValue(for: unit)
                let dur = max(1, s.endDate.timeIntervalSince(s.startDate))
                vals.append((db: db, dur: dur))
            }
            DispatchQueue.main.async {
                if let error = error, vals.isEmpty {
                    self?.state = .unavailable("記録を読めませんでした（\(error.localizedDescription)）。")
                    return
                }
                self?.apply(vals)
                self?.state = .loaded
            }
        }
        store.execute(q)
    }

    private func apply(_ vals: [(db: Double, dur: Double)]) {
        guard let s = Model.exposureStats(vals) else {
            sampleCount = 0
            return
        }
        sampleCount = vals.count
        average = s.average
        p90 = s.p90
        maximum = s.maximum
        totalHours = s.hours
    }
}
