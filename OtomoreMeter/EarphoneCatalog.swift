import Foundation

enum RouteKind: String, Codable {
    case wired, bluetooth, speaker, other

    var name: String {
        switch self {
        case .wired: return "有線"
        case .bluetooth: return "Bluetooth"
        case .speaker: return "スピーカー"
        case .other: return "その他"
        }
    }

    var isHeadphones: Bool { self == .wired || self == .bluetooth }
}

/// 接続中のイヤホンの名前（例:「宏伸のAirPods Pro」「WF-1000XM5」）から種類を推定する
enum EarphoneCatalog {
    private struct Rule {
        let keys: [String]
        let type: EarType
    }

    // 上から順に照合する（より具体的な名前を先に）
    private static let rules: [Rule] = [
        Rule(keys: ["airpods max"], type: .hpclosed),
        Rule(keys: ["airpods pro"], type: .canal),
        Rule(keys: ["airpods"], type: .inner),
        Rule(keys: ["earpods"], type: .inner),
        Rule(keys: ["solo buds", "studio buds", "fit pro", "powerbeats", "beats flex", "beatsx"], type: .canal),
        Rule(keys: ["beats studio", "studio pro", "studio3"], type: .hpclosed),
        Rule(keys: ["beats solo", "solo pro", "solo3", "solo 4"], type: .hpopen),
        Rule(keys: ["linkbuds open", "float run", "ambie", "am-tw", "earcuffs", "openfit", "opendots",
                    "ultra open", "aerofit", "oladance", "cleer arc", "freeclip", "nwm", "ear (open)", "ear(open)"],
             type: .open),
        Rule(keys: ["linkbuds s", "linkbuds fit", "wf-", "galaxy buds", "pixel buds", "liberty", "space a40",
                    "p40i", "p3i", "life p", "jabra elite", "eah-az", "nothing ear", "cmf buds",
                    "quietcomfort ultra earbuds", "qc ultra earbuds", "quietcomfort earbuds", "qc earbuds",
                    "sport earbuds", "ath-ck", "ath-sq", "ath-twx", "momentum true", "momentum tw", "cx plus"],
             type: .canal),
        Rule(keys: ["linkbuds"], type: .open),
        Rule(keys: ["openrun", "openmove", "opencomm", "openswim", "aeropex", "aftershokz", "shokz"], type: .bone),
        Rule(keys: ["wh-", "ult wear", "quietcomfort", "qc45", "qc35", "headphones 700", "momentum 4",
                    "space one", "space q45", "life q", "ath-m", "eah-a800"],
             type: .hpclosed)
    ]

    static func guess(name: String) -> EarType? {
        let n = name.lowercased()
        for rule in rules {
            for key in rule.keys where n.contains(key) {
                return rule.type
            }
        }
        return nil
    }

    static func symbol(name: String, kind: RouteKind) -> String {
        let n = name.lowercased()
        if kind == .speaker { return "speaker.wave.2" }
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        return "headphones"
    }
}
