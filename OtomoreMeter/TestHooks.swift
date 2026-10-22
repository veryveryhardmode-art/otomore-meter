import Foundation

/// シミュレーターでの自動テスト用の差し替え。環境変数が無いときは何もしない（ふつうに使うときは無関係）
enum TestHooks {
    private static let env = ProcessInfo.processInfo.environment

    /// 音量（0〜1）
    static var mockVolume: Double? { env["OTOMORE_MOCK_VOLUME"].flatMap { Double($0) } }
    /// 接続中のイヤホン名
    static var mockRouteName: String? { env["OTOMORE_MOCK_ROUTE"] }
    static var mockRouteKind: RouteKind { env["OTOMORE_MOCK_ROUTE_KIND"].flatMap { RouteKind(rawValue: $0) } ?? .bluetooth }
    /// マイクの代わりに合成した録音を使う（テスト音も鳴らさない）
    static var mockMic: Bool { env["OTOMORE_MOCK_MIC"] == "1" }
    /// 合成録音の周りの音
    static var mockScene: (dBA: Double, shape: [Double]) {
        switch env["OTOMORE_MOCK_SCENE"] ?? "room" {
        case "train": return (68, Model.shapeTrain)
        case "office": return (50, Model.shapeOffice)
        default: return (40, Model.shapeQuiet)
        }
    }
    /// 合成録音で「本当に」漏れているイヤホンの種類（省略時はイヤホン名から判定した種類）
    static var mockTrueType: EarType? { env["OTOMORE_MOCK_TRUE_TYPE"].flatMap { EarType(rawValue: $0) } }
    /// ヘルスケアのヘッドフォン音量の代わり（"dB:秒,dB:秒,..."）
    static var mockHealth: [(db: Double, dur: Double)]? {
        guard let s = env["OTOMORE_MOCK_HEALTH"] else { return nil }
        return s.split(separator: ",").compactMap { p -> (db: Double, dur: Double)? in
            let a = p.split(separator: ":")
            guard a.count == 2, let d = Double(a[0]), let t = Double(a[1]) else { return nil }
            return (db: d, dur: t)
        }
    }
    /// 保存データを消してから起動する
    static var reset: Bool { env["OTOMORE_RESET"] == "1" }
}
