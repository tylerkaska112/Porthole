import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { if ok { print("PASS: \(what)") } else { failures += 1; print("FAIL: \(what)") } }

func badge(_ v: CompatVerdict?, earlier: Int = 0, past: CompatVerdict? = nil) -> CompatBadge {
    CompatBadge(overall: v.map { CompatVerdictInfo(verdict: $0, reports: 3, confidence: "high") }, forDevice: nil, verdict: v,
                earlier: CompatEarlier(reports: earlier, verdict: past, engine: "old", appVersion: past == nil ? nil : "1.1.0", date: nil, verdictReports: nil))
}
func item(_ title: String, _ v: CompatVerdict?, reports: Int, last: String?, library: Bool = false, earlier: Int = 0, past: CompatVerdict? = nil) -> ReportsItem {
    ReportsItem(id: title, gameID: title, title: title, reportCount: reports, lastReport: last, badge: badge(v, earlier: earlier, past: past), libraryID: library ? UUID() : nil)
}

@main struct Main {
    static func main() {
        let items = [
            item("Factorio", .great, reports: 41, last: "2026-11-02"),
            item("The Forest", .playable, reports: 18, last: "2026-11-01"),
            item("Celeste", .great, reports: 6, last: "2026-11-03"),
            item("Black Ops III", .broken, reports: 9, last: "2026-10-28"),
            item("Unturned", nil, reports: 0, last: nil, library: true),
            item("Assetto Corsa", nil, reports: 2, last: "2026-10-12", library: true, earlier: 2, past: .great),
            item("Éclair Quest", .great, reports: 41, last: "2026-10-01"),
        ]
        func names(_ f: ReportsFilter, _ o: ReportsOrder, _ q: String = "") -> [String] { ReportsLogic.visible(items, filter: f, order: o, query: q).map(\.title) }

        check(names(.all, .popular) == ["Factorio", "Éclair Quest", "The Forest", "Black Ops III", "Celeste", "Unturned", "Assetto Corsa"].filter { _ in true }.sorted { a, b in
            let c: [String: Int] = ["Factorio": 41, "Éclair Quest": 41, "The Forest": 18, "Black Ops III": 9, "Celeste": 6, "Unturned": 0, "Assetto Corsa": 2]
            return c[a]! > c[b]! || (c[a]! == c[b]! && items.firstIndex { $0.title == a }! < items.firstIndex { $0.title == b }!)
        }, "most reports first, ties keep the server's order")
        check(names(.great, .popular) == ["Factorio", "Éclair Quest", "Celeste"], "the Works great filter keeps only great games")
        check(names(.broken, .popular) == ["Black Ops III"], "the Doesn't work filter")
        check(names(.untested, .popular) == ["Assetto Corsa", "Unturned"], "Not yet tested keeps games with no verdict on this engine, even one with an earlier report")
        check(names(.all, .name).first == "Assetto Corsa" && names(.all, .name).last == "Unturned" && names(.all, .name)[3] == "Éclair Quest", "A to Z")
        check(names(.all, .recent).prefix(3) == ["Celeste", "Factorio", "The Forest"], "recent puts the newest report first")
        check(names(.all, .recent).last == "Unturned", "a game with no date goes last in Recent")
        check(names(.all, .popular, "eclair") == ["Éclair Quest"], "search ignores case and accents")
        check(names(.all, .popular, "  forest ") == ["The Forest"], "search trims spaces")
        check(names(.great, .recent, "t") == ["Celeste", "Factorio", "Éclair Quest"], "filter, search and order together")

        let s = ReportsLogic.summary(items)
        check(s.total == 7 && s.great == 3 && s.playable == 1 && s.broken == 1 && s.untested == 2 && s.tested == 5, "summary counts")
        check(items.first { $0.title == "Unturned" }!.needsReport && items.first { $0.title == "Assetto Corsa" }!.needsReport, "a library game with no verdict needs a report")
        check(!items.first { $0.title == "Factorio" }!.needsReport, "a game with a verdict, or not in the library, does not")

        let samples: [ReportsLogic.Sample] = [
            .init(rating: .great, tags: ["controller_ok", "overheats"], onThisEngine: true, deviceID: "a"),
            .init(rating: .great, tags: ["controller_ok"], onThisEngine: true, deviceID: "b"),
            .init(rating: .playable, tags: ["overheats", "overheats"], onThisEngine: true, deviceID: "a"),
            .init(rating: .broken, tags: ["audio_issues"], onThisEngine: false, deviceID: "a"),
        ]
        let b = ReportsLogic.breakdown(samples)
        check(b.great == 2 && b.playable == 1 && b.broken == 0 && b.earlier == 1 && b.total == 3, "breakdown counts this engine's reports and only counts the earlier ones")
        check(b.tags.map(\.tag) == ["controller_ok", "overheats"] && b.tags.map(\.count) == [2, 2], "tags count once per report and ignore earlier engines")
        check(abs(b.fraction(.great) - 2.0 / 3.0) < 0.0001, "fraction")
        let onlyA = ReportsLogic.breakdown(samples, deviceID: "a")
        check(onlyA.great == 1 && onlyA.playable == 1 && onlyA.earlier == 1, "one device's breakdown")
        check(ReportsLogic.breakdown([]).total == 0 && ReportsLogic.breakdown([]).fraction(.great) == 0, "no reports")
        check(ReportsLogic.breakdown(samples, topTags: 1).tags.count == 1, "top tags limit")

        print(failures == 0 ? "reports logic: PASS" : "reports logic: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
