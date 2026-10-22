import SwiftUI
import UIKit
import Charts

// MARK: - 色

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Palette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    static let levels: [Color] = [
        dynamic(0x13906C, 0x3FC69A),
        dynamic(0x5B962A, 0x95CD5B),
        dynamic(0xC4860C, 0xEFB444),
        dynamic(0xD4521C, 0xFF8752),
        dynamic(0xC01D48, 0xFF5F86)
    ]

    static let accent = dynamic(0x2A46CC, 0x8C9DFF)

    static func level(_ l: Int) -> Color {
        levels[max(0, min(levels.count - 1, l))]
    }
}

// MARK: - 部品

struct LevelPill: View {
    let level: Int

    var body: some View {
        let c = Palette.level(level)
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<5, id: \.self) { k in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(k <= level ? c : c.opacity(0.25))
                        .frame(width: 4, height: CGFloat(6 + k * 2))
                }
            }
            Text(Model.levelNames[max(0, min(4, level))])
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .foregroundColor(c)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(c.opacity(0.15)))
        .fixedSize()
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct PlaceRow: View {
    let place: Place
    let eval: PlaceEval
    let safe: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.body.weight(.semibold))
                Text("\(place.whereText)・\(Int((place.distance * 100).rounded()))cm・周りの音 \(Int(place.dBA))dB")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                LevelPill(level: eval.level)
                Text(safe)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 内訳

struct BandBar: Identifiable {
    let id: String
    let band: String
    let kind: String
    let value: Double
    let color: Color
}

struct PlaceDetailView: View {
    let title: String
    let subtitle: String
    let eval: PlaceEval

    private func clamp(_ v: Double) -> Double {
        v.isFinite ? max(0, min(90, v)) : 0
    }

    private var bars: [BandBar] {
        var out: [BandBar] = []
        for i in 0..<Model.bandLabels.count {
            let amb = max(eval.ambient[i], Model.hearing[i])
            out.append(BandBar(id: "a\(i)", band: Model.bandLabels[i], kind: "周りの音",
                               value: clamp(amb), color: Color.secondary.opacity(0.35)))
            if let n = eval.neighbor[i], let g = eval.margin[i] {
                out.append(BandBar(id: "l\(i)", band: Model.bandLabels[i], kind: "漏れ音",
                                   value: clamp(n), color: Palette.level(Model.levelOf(g))))
            }
        }
        return out
    }

    private var note: String {
        let i = eval.worstBand
        guard i >= 0, let n = eval.neighbor[i], let g = eval.margin[i] else {
            return "音が出ていないので、漏れもありません。"
        }
        let amb = max(eval.ambient[i], Model.hearing[i])
        var s = "いちばん目立つのは \(Model.bandLabels[i])Hz 帯です。隣の人の耳の位置で約\(Int(n.rounded()))dB、周りの音は約\(Int(amb.rounded()))dB（差 \(signedText(g))dB）。"
        if i >= 4 {
            s += "高い音ほどイヤホンから漏れやすく、乗り物の騒音（低い音が中心）にも埋もれにくいので、シャカシャカ音として目立ちます。"
        } else if i <= 2 {
            s += "低めの音が漏れています。耳への密着が甘いと低音が抜けやすくなります。"
        }
        return s
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LevelPill(level: eval.level)
                    Text(Model.levelDescs[eval.level])
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            Section {
                Chart(bars) { b in
                    BarMark(
                        x: .value("帯域", b.band),
                        y: .value("dB", b.value)
                    )
                    .foregroundStyle(b.color)
                    .position(by: .value("種類", b.kind))
                }
                .chartYScale(domain: 0.0...90.0)
                .chartXAxisLabel("帯域（Hz）")
                .chartYAxisLabel("dB")
                .frame(height: 240)
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 6) {
                    legendItem(color: Color.secondary.opacity(0.35), text: "周りの音")
                    legendItem(color: Palette.level(2), text: "隣の人の耳に届く漏れ音（色は目立ち具合）")
                }
                .font(.caption)
                Text(note)
                    .font(.footnote)
            } header: {
                Text("帯域ごとの内訳")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 実測の画面

struct MeasureSheet: View {
    @ObservedObject var measurer: Measurer
    let latest: MeasureResult?
    let hereLevel: Int?
    let canMeasure: Bool
    let onStart: () -> Void
    let onClose: () -> Void

    private var running: Bool { measurer.isRunning }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        stepRow(1, "イヤホンを両耳に着けて、ふだん聴く音量にします。")
                        stepRow(2, "「測定をはじめる」を押したら、3秒以内にiPhoneの下の端（充電口の横のマイク）を、片方の耳のすぐ前の頬に軽く当てます。")
                        stepRow(3, "そのまま静かに待ちます。周りの音を3秒、テスト音を4秒測ります。テスト音が止まってiPhoneが震えたら終わりです。")
                    }
                    Text("測定中は、ほかのアプリの音楽が一時停止します。録音した音は保存も送信もしません。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    statusView
                    if running {
                        ProgressView(value: measurer.progress)
                    }
                    Button(action: onStart) {
                        Text(buttonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || !canMeasure)
                    if !canMeasure {
                        Text("イヤホンをつないでから測ってください。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("音漏れを測る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(running ? "中止" : "閉じる") {
                        if running {
                            measurer.cancel()
                        } else {
                            onClose()
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(running)
    }

    private var buttonTitle: String {
        switch measurer.phase {
        case .done, .failed(_):
            return "もう一度測る"
        default:
            return "測定をはじめる"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch measurer.phase {
        case .idle:
            EmptyView()
        case .countdown(let n):
            statusText("iPhoneの下の端を、耳のすぐ前に当ててください　\(n)", color: Palette.accent)
        case .ambient:
            statusText("周りの音を測っています。静かにしていてください", color: Palette.accent)
        case .tone:
            statusText("テスト音を測っています", color: Palette.accent)
        case .done:
            VStack(alignment: .leading, spacing: 10) {
                statusText("測定が終わりました", color: Palette.level(0))
                if let lvl = hereLevel {
                    HStack {
                        Text("測った場所での判定")
                            .font(.subheadline)
                        Spacer()
                        LevelPill(level: lvl)
                    }
                }
                if let m = latest {
                    Text("6帯域のうち \(m.detectedCount) 帯域で音漏れを検出しました。閉じると、場面ごとの判定が実測をもとにした値に切り替わります。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        case .failed(let msg):
            statusText(msg, color: Palette.level(4))
        }
    }

    private func statusText(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.title3.weight(.semibold))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Palette.accent))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 計算のしかた

struct AboutView: View {
    private let items: [(String, String)] = [
        ("音量", "iPhoneの音量（16段階）を自動で読み取ります。dBへの換算は、AirPodsで実測された10%ごとの値を使っています。最大音量で耳に届く音は約100dB（ヨーロッパの規格EN 50332の上限）としています。"),
        ("イヤホンの種類", "接続中のイヤホンの名前から判定します（AirPods Pro → カナル型、AirPods → インナーイヤー型 など）。判定できないときや違うときは手動で選べます。選んだ種類はイヤホンごとに覚えます。"),
        ("推定", "イヤホンの種類ごとに、帯域（125Hz〜8kHz）別の「耳から10cmへ漏れる量」を目安値で持っています。高い音ほど漏れやすい設定です。値は、静かな部屋でAirPods Pro・有線イヤホン・骨伝導を20cmと1mで聞き比べた公開記録に合うよう補正しています。"),
        ("実測", "iPhoneの下のマイクを耳の約3cm横に当て、周りの音とテスト音を測ります。2つの差から、イヤホンから漏れた音だけを取り出します。テスト音は一般的な曲と同じ帯域バランスで、ふつうの曲より3dB小さく流しています。AirPodsは高音質のまま鳴らし、マイクはiPhone本体のものを使います。"),
        ("隣の人までの距離", "耳から10cmの漏れ音をもとに、距離が2倍で約6dB下がる計算に、車内や室内の反響ぶんを少し加えています。"),
        ("判定", "帯域ごとに、隣の人の耳に届く漏れ音と周りの騒音を比べ、いちばん目立つ帯域で判定します。騒音より12dB以上小さければ聞こえない、6dB以上小さければほぼ気づかれない、騒音を超えると気になる、8dB以上超えて歌やメロディの帯域（500Hz〜2kHz）も聞こえていれば曲までわかる、としています。"),
        ("場面の騒音", "新幹線・バスの車内の約70dB、書店の約50dB、図書館の約40dBは名古屋市「騒音の目安」をもとにしています。ほかは目安値です。"),
        ("精度", "誤差は±5dB程度です。マイクの感度は機種共通の目安値を使っています。「測った場所での判定」は漏れた音と周りの音を同じマイクで比べるので、感度のずれの影響を受けません。場面の物差しの精度を上げたいときは、校正済みの騒音計アプリで同じ場所を測り、「測ったときの周りの音」との差をマイクの補正に入れてください。")
    ]

    var body: some View {
        List {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(items[i].0)
                        .font(.subheadline.weight(.semibold))
                    Text(items[i].1)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("計算のしかた")
        .navigationBarTitleDisplayMode(.inline)
    }
}
