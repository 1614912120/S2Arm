// S2Arm（不是上游文件）：S 级优化每一类（满屏 / 帧率 / 画面）此刻是什么状态、给玩家看哪一句（cmdr/S级状态与文案_三端对照_体验梳理线_1115.md 定稿）。
//   数据来自作业层 describe_game 的 sgradeState（D2R 线，pack/jobs/community.py）；同一状态在设置、出包页、升级页说同一句（文案键 sgrade.state.*）。
//   纯函数：输入一类的状态字典，输出那一句 + 要不要给「重新打开」（作业 sgradeReenable 的 key）。没有 sgradeState（作业层还没出这个字段）= 不画
import Foundation

struct SGradeCategoryState: Equatable {
    var state = ""            // on / ineffective / off_user / off_auto / version / none / opted_out / pending / mac_only / unknown
    var source = ""           // 满屏：patch / ported / own / none
    var activeName = "", ratio = "", portedFrom = ""
    var target = 0            // 帧率：目标帧率
    var lastRun = ""          // 上一局结果原句（作业层 patch_result，中文原句，界面经 BackendText 翻）
    var autoOffCause = "", autoOffAt: Date? = nil
    var mine = "", available: [String] = [], port = ""

    init(_ raw: [String: Any]) {
        state = raw["state"] as? String ?? ""; source = raw["source"] as? String ?? ""
        let active = raw["active"] as? [String: Any] ?? [:]
        activeName = active["name"] as? String ?? ""; ratio = active["ratio"] as? String ?? ""; portedFrom = active["from"] as? String ?? ""
        target = (raw["target"] as? NSNumber)?.intValue ?? 0
        lastRun = (raw["lastRun"] as? [String: Any])?["text"] as? String ?? ""
        let off = raw["autoOff"] as? [String: Any] ?? [:]
        autoOffCause = off["cause"] as? String ?? ""
        autoOffAt = (off["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let v = raw["versions"] as? [String: Any] ?? [:]
        mine = v["mine"] as? String ?? ""; available = v["available"] as? [String] ?? []; port = v["port"] as? String ?? ""
    }
}

enum SGradeStateText {
    /// 版本号按段比较（1.10 > 1.9；段数不同短的补 0）
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    /// 一类的那一句。cat = widescreen / fps / gfx；catName = 这一类给玩家看的名字（export.sgrade.cat.*）；t = 取文案；date = 日期写法；
    ///   backend = 作业层中文原句译成界面语言。→ (那一句, 「重新打开」要传的 key；nil = 不给按钮)；没有可说的 = nil
    static func line(cat: String, catName: String, _ s: SGradeCategoryState, t: (String) -> String,
                     date: (Date) -> String, backend: (String) -> String = { $0 }) -> (text: String, reenable: String?)? {
        func f(_ id: String, _ args: String...) -> String {
            args.enumerated().reduce(t(id)) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element) }
        }
        let key = cat == "widescreen" ? "fullscreen" : cat
        switch s.state {
        case "on":
            if cat == "fps", s.target > 0 { return (f("sgrade.state.on.fps", "\(s.target)"), nil) }
            if cat == "widescreen" {
                switch s.source {
                case "own": return (t("sgrade.state.on.own"), nil)
                case "ported": return (f("sgrade.state.on.ported", s.activeName, s.portedFrom.isEmpty ? (s.available.first ?? "") : s.portedFrom), nil)
                default: return s.activeName.isEmpty ? nil : (f("sgrade.state.on.patch", s.activeName, s.ratio), nil)
                }
            }
            return nil
        case "ineffective": return s.lastRun.isEmpty ? nil : (backend(s.lastRun), nil)   // 作业层原句本身就写「没生效：… / 开着，但上一局…」，不再套一层
        case "off_user": return (t("sgrade.state.off_user"), nil)
        case "off_auto":
            let when = s.autoOffAt.map(date) ?? ""
            return (f(s.autoOffCause == "stall" ? "sgrade.state.off_auto.stall" : "sgrade.state.off_auto.crash", when), key)
        case "version":
            // 总指挥 11-15 定：写离玩家最近、且比它新的那个版本；全是旧版本写「只有旧版本 X 的」，不劝降级
            let newer = s.available.filter { compare($0, s.mine) > 0 }.sorted { compare($0, $1) < 0 }
            var text: String
            if let v = newer.first { text = f("sgrade.state.version.newer", v, s.mine) }
            else if let v = s.available.sorted(by: { compare($0, $1) < 0 }).last { text = f("sgrade.state.version.older", v) }
            else { return nil }
            if cat == "widescreen", s.port == "failed" { text += t("sgrade.state.version.port_failed") }
            return (text, nil)
        case "none": return (f("sgrade.state.none", catName), nil)
        case "opted_out": return (t("sgrade.state.opted_out"), nil)
        case "mac_only": return (t("sgrade.state.mac_only"), nil)
        default: return nil   // pending（Mac 下次起局自动补上，不用说）/ unknown / 还没有这个字段
        }
    }
}
