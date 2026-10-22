import SwiftUI

struct ContentView: View {
    @ObservedObject var monitor: AudioMonitor
    @ObservedObject var measurer: Measurer
    @ObservedObject var prefs: UserPrefs
    @ObservedObject var health: HealthLevels
    @State private var showMeasure = false

    // MARK: - 計算に使う値

    private var volumePct: Double { monitor.volume * 100 }
    private var step: Int { Int((monitor.volume * 16).rounded()) }
    private var deviceKey: String { monitor.routeName.isEmpty ? "(なし)" : monitor.routeName }
    private var overrideType: EarType? { prefs.overrides[deviceKey] }
    private var earType: EarType { overrideType ?? monitor.guessedType ?? .canal }
    private var measurement: MeasureResult? { prefs.measurements[deviceKey] }
    private var usingMeasured: Bool { prefs.useMeasured && measurement != nil }
    private var calibration: Double { Model.micCalibration + prefs.micOffset }
    private var isMuted: Bool { monitor.volume < 0.001 }

    /// 耳から10cmの漏れ音（帯域ごと）。実測があれば、いまの音量に換算して使う
    private var leak: [Double?] {
        if usingMeasured, let m = measurement {
            let shift = Model.volDb(volumePct) - Model.volDb(m.volume * 100) + prefs.loudness.db + (calibration - m.calibration)
            return m.leak10.map { v in v.map { $0 + shift } }
        }
        return Model.estimatedLeak(type: earType, fit: prefs.fit, volumePct: volumePct, loudness: prefs.loudness)
    }

    /// 実測で「測りきれなかった」帯域（上限値しかない帯域）
    private var upperBound: [Bool]? {
        guard usingMeasured, let m = measurement else { return nil }
        return m.detected.map { !$0 }
    }

    private func eval(_ p: Place) -> PlaceEval {
        Model.evaluate(leak: leak, place: p, upperBound: upperBound)
    }

    private func hereEval(_ m: MeasureResult) -> PlaceEval {
        let shiftCal = calibration - m.calibration
        let shifted: [Double?] = m.ambientDb.map { v in v.map { $0 + shiftCal } }
        return Model.evaluate(leak: leak, ambient: Model.hereAmbient(shifted), distance: Model.neighborDistance,
                              upperBound: m.detected.map { !$0 })
    }

    private func safeSteps(_ ev: PlaceEval) -> Int? {
        if isMuted { return nil }
        return Model.steps(fromPct: Model.safeVolumePct(current: volumePct, worstMargin: ev.worstMargin))
    }

    private func safeLabel(_ s: Int?, uncertain: Bool = false) -> String {
        guard let s = s else { return "—（無音）" }
        if s >= 16 { return "最大音量でもOK" }
        if uncertain {
            return s <= 0 ? "測りきれず" : "少なくとも \(s) / 16 まではOK"
        }
        if s <= 0 { return "1段階でも漏れる" }
        return "\(s) / 16 までOK"
    }

    /// その場面で「ほぼ気づかれない」に収まる、耳に届く音の大きさ
    private func earLimit(_ ev: PlaceEval) -> Double? {
        if isMuted { return nil }
        let cur = Model.earLevel(volumePct: volumePct, loudness: prefs.loudness)
        return Model.safeEarDb(currentEar: cur, worstMargin: ev.worstMargin)
    }

    private func earLimitText(_ ev: PlaceEval) -> String {
        guard let e = earLimit(ev) else { return "耳の音：—" }
        if !e.isFinite || e >= Model.maxEar { return "耳で何dBでもOK" }
        let v = Int(e.rounded())
        return ev.uncertain ? "耳で少なくとも約\(v)dBまで" : "耳で約\(v)dBまで"
    }

    private func placeIndex(_ id: String) -> Int {
        Model.places.firstIndex(where: { $0.id == id }) ?? 0
    }

    // MARK: - 画面

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                listeningSection
                summarySection
                measureSection
                if usingMeasured, let m = measurement {
                    hereSection(m)
                }
                ladderSection
                healthSection
                detailSection
            }
            .navigationTitle("音漏れメーター")
            .sheet(isPresented: $showMeasure) {
                MeasureSheet(
                    measurer: measurer,
                    latest: measurement,
                    hereLevel: measurement.map { hereEval($0).level },
                    canMeasure: monitor.routeKind.isHeadphones,
                    onStart: startMeasurement,
                    onClose: { showMeasure = false }
                )
            }
        }
    }

    private var deviceSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: EarphoneCatalog.symbol(name: monitor.routeName, kind: monitor.routeKind))
                    .font(.title2)
                    .foregroundColor(Palette.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.routeKind.isHeadphones ? monitor.routeName : "イヤホンがつながっていません")
                        .font(.headline)
                    Text(monitor.routeKind.isHeadphones ? "\(monitor.routeKind.name)で接続中" : "いまはiPhoneのスピーカーから音が出ています")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
            if monitor.routeKind.isHeadphones {
                Picker("種類", selection: typeBinding) {
                    ForEach(EarType.allCases) { t in
                        Text(t.name).tag(t)
                    }
                }
                Text(typeCaption)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("イヤホン")
        }
    }

    private var typeBinding: Binding<EarType> {
        Binding(
            get: { earType },
            set: { newValue in
                if let g = monitor.guessedType, g == newValue {
                    prefs.overrides[deviceKey] = nil
                } else {
                    prefs.overrides[deviceKey] = newValue
                }
            }
        )
    }

    private var typeCaption: String {
        if overrideType != nil { return "手動で選んだ種類です。このイヤホンの種類として覚えておきます。" }
        if monitor.guessedType != nil { return "イヤホンの名前から自動で判定しました。違う場合は変更してください。" }
        return "機種を判定できませんでした。種類を選んでください。"
    }

    private var earText: String {
        if isMuted { return "無音" }
        let ear = Model.earLevel(volumePct: volumePct, loudness: prefs.loudness)
        let base = "耳に届く音 約\(Int(ear.rounded()))dB（推定）"
        return ear > 85 ? base + "。長く聴くと耳への負担が大きい音量です" : base
    }

    private var listeningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("音量")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(step)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("/ 16")
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < step ? Palette.accent : Color.secondary.opacity(0.2))
                            .frame(height: 8)
                    }
                }
                Text(earText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("曲の音圧")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("曲の音圧", selection: $prefs.loudness) {
                    ForEach(Loudness.allCases) { l in
                        Text(l.name).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                Text(prefs.loudness.example)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

            if earType.hasFit && !usingMeasured {
                VStack(alignment: .leading, spacing: 6) {
                    Text("イヤーピースのフィット")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("フィット", selection: $prefs.fit) {
                        ForEach(Fit.allCases) { f in
                            Text(f.name).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("聴き方")
        } footer: {
            Text("音量はiPhoneから自動で読み取っています。音量ボタンを押すと、その場で判定が変わります。")
        }
    }

    private var summarySection: some View {
        let evals = Model.places.map { eval($0) }
        let run = evals[placeIndex("shinRun")]
        let stop = evals[placeIndex("shinStop")]
        let noticed = zip(Model.places, evals).filter { $0.1.level >= 2 }.map { $0.0.name }
        let safePairs = evals.compactMap { e -> (Int, Bool)? in safeSteps(e).map { ($0, e.uncertain) } }
        let minSafe = safePairs.map { $0.0 }.min()
        let minUncertain = safePairs.contains { $0.0 == minSafe && $0.1 }
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("新幹線で使うなら（停車中が基準）")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                HStack(alignment: .center, spacing: 10) {
                    LevelPill(level: stop.level)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(safeLabel(safeSteps(stop), uncertain: stop.uncertain))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(earLimitText(stop))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Palette.accent)
                            .monospacedDigit()
                    }
                }
                Text(stop.uncertain && stop.level > 0 ? "測りきれなかったので、これ以下です。" : Model.levelDescs[stop.level])
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("走行中は「\(Model.levelNames[run.level])」ですが、駅に止まった瞬間に周りが静かになるので、停車中を基準にしています。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            LabeledRow(label: "気づかれやすい場面", value: noticed.isEmpty ? "なし" : noticed.joined(separator: "、"))
            LabeledRow(label: "どこでもセーフな音量", value: safeLabel(minSafe, uncertain: minUncertain))
        } header: {
            Text(usingMeasured ? "判定（実測をもとに計算）" : "判定（音量と種類から推定）")
        } footer: {
            if !monitor.routeKind.isHeadphones {
                Text("イヤホンをつなぐと、そのイヤホンで判定します。")
            } else {
                Text("耳に届いている音は、コントロールセンターの「聴覚」（耳のアイコン）で、聴きながらdBで確かめられます。AirPodsやBeatsはiPhoneが測った値です。")
            }
        }
    }

    private var measureSection: some View {
        Section {
            Button {
                showMeasure = true
            } label: {
                Label("iPhoneを耳の横に当てて実測する", systemImage: "waveform")
            }
            .disabled(!monitor.routeKind.isHeadphones)
            if let m = measurement {
                Picker("判定に使う値", selection: $prefs.useMeasured) {
                    Text("実測を使う").tag(true)
                    Text("推定を使う").tag(false)
                }
                .pickerStyle(.segmented)
                Text(measuredCaption(m))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("実測")
        } footer: {
            Text("AirPodsでも有線でも同じやり方です。iPhoneのマイクで測るので、ケーブルの電気的な回り込みは入りません。")
        }
    }

    private func measuredCaption(_ m: MeasureResult) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        let st = Int((m.volume * 16).rounded())
        var s = "\(f.string(from: m.date)) に音量 \(st)/16 で測定。\(Model.bandFreqs.count - 1)帯域のうち \(m.detectedCount) 帯域で音漏れを検出。"
        if m.detectedCount == 0 {
            s += "テスト音が周りの音に埋もれたので、漏れは「これ以下」という上限で判定しています。"
        }
        s += "音量を変えると、いまの音量に換算して判定します。"
        return s
    }

    private func hereSection(_ m: MeasureResult) -> some View {
        let ev = hereEval(m)
        let ambText: String
        if let a = m.ambientA {
            ambText = "測ったときの周りの音 約\(Int((a + calibration - m.calibration).rounded()))dB・隣の席55cm"
        } else {
            ambText = "測ったときの周りの音・隣の席55cm"
        }
        return Section {
            NavigationLink {
                PlaceDetailView(title: "測った場所", subtitle: ambText, eval: ev)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("測った場所で、隣に人がいたら")
                            .font(.body.weight(.semibold))
                        Text(ambText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        LevelPill(level: ev.level)
                        Text(safeLabel(safeSteps(ev), uncertain: ev.uncertain))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(earLimitText(ev))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("測った場所での判定")
        } footer: {
            Text("漏れた音と周りの音を同じマイクで比べた結果です。新幹線の車内で測れば、その車内での判定になります。")
        }
    }

    private var ladderSection: some View {
        Section {
            ForEach(Model.places) { place in
                let ev = eval(place)
                NavigationLink {
                    PlaceDetailView(
                        title: place.name,
                        subtitle: "\(place.whereText)・\(Int((place.distance * 100).rounded()))cm・周りの音 \(Int(place.dBA))dB",
                        eval: ev
                    )
                } label: {
                    PlaceRow(place: place, eval: ev, safe: safeLabel(safeSteps(ev), uncertain: ev.uncertain), ear: earLimitText(ev))
                }
            }
        } header: {
            Text("場面の物差し")
        } footer: {
            Text("上ほど静かで、音漏れに厳しい場面です。右下は、その場面で気づかれない音量の上限と、そのときの耳に届く音の大きさです。")
        }
    }

    private var healthSection: some View {
        let stop = eval(Model.places[placeIndex("shinStop")])
        let limit = earLimit(stop)
        return Section {
            switch health.state {
            case .idle:
                Button("ヘルスケアから読み込む") { health.load() }
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("読み込んでいます…")
                }
            case .unavailable(let msg):
                Text(msg)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("もう一度試す") { health.load() }
            case .loaded:
                if health.sampleCount == 0 {
                    Text("直近30日のヘッドフォン音量の記録がありませんでした。AirPodsで音楽を聴くと、iPhoneが自動で記録します。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    LabeledRow(label: "ふだんの音（平均）", value: "約\(Int(health.average.rounded()))dB")
                    LabeledRow(label: "大きいとき（上位10%）", value: "約\(Int(health.p90.rounded()))dB")
                    LabeledRow(label: "いちばん大きいとき", value: "約\(Int(health.maximum.rounded()))dB")
                    LabeledRow(label: "記録の量", value: String(format: "%.1f時間・%d件", health.totalHours, health.sampleCount))
                    Text(healthVerdict(limit: limit))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("読み込み直す") { health.load() }
            }
        } header: {
            Text("ふだん聴いている音の大きさ（ヘルスケア）")
        } footer: {
            Text("iPhoneが記録している「ヘッドフォン音量」の直近30日分です。AirPodsやBeatsはiPhoneが測った値、ほかのイヤホンは音量からの推定です。")
        }
    }

    private func healthVerdict(limit: Double?) -> String {
        guard let l = limit else {
            return "音量が0のあいだは比べられません。音量を上げると、新幹線の停車中の上限と比べます。"
        }
        if !l.isFinite || l >= Model.maxEar {
            return "いまのイヤホンなら、最大音量でも新幹線の停車中の上限を超えません。"
        }
        let lv = Int(l.rounded())
        if health.p90 <= l {
            return "大きいときでも、新幹線の停車中の上限（耳で約\(lv)dB）以内です。"
        }
        if health.average <= l {
            return "ふだんは大丈夫ですが、大きいときは新幹線の停車中の上限（耳で約\(lv)dB）を超えています。"
        }
        return "ふだんの音で、新幹線の停車中の上限（耳で約\(lv)dB）を超えています。"
    }

    private var detailSection: some View {
        Section {
            Stepper(value: $prefs.micOffset, in: -15...15, step: 1) {
                HStack {
                    Text("マイクの補正")
                    Spacer()
                    Text("\(signedText(prefs.micOffset)) dB")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            NavigationLink {
                AboutView()
            } label: {
                Text("計算のしかた")
            }
        } header: {
            Text("詳細")
        } footer: {
            Text("実測で出る「周りの音」が、校正済みの騒音計アプリの値とずれるときに合わせます。")
        }
    }

    private func startMeasurement() {
        let key = deviceKey
        let name = monitor.routeName
        let cal = calibration
        monitor.isPaused = true
        Task { @MainActor in
            let result = await measurer.run(calibration: cal, routeName: name) {
                monitor.isPaused = false
                monitor.activate()
            }
            if let r = result {
                prefs.measurements[key] = r
                prefs.useMeasured = true
            }
        }
    }
}
