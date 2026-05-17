import Foundation

/// Pragmatic parser for OpenStreetMap's `opening_hours` tag grammar.
/// See https://wiki.openstreetmap.org/wiki/Key:opening_hours for the
/// canonical spec.
///
/// We handle the subset that covers ~all real-world restaurant tagging:
///
/// - Rules separated by `;` (semicolon)
/// - Day specs: ranges (`Mo-Fr`), lists (`Mo,We,Fr`), single days
///   (`Sa`). Uppercase and lowercase weekday tokens accepted.
/// - Time specs: `HH:MM-HH:MM`, multiple windows per day separated by
///   `,` (we keep only the first window — the `hours` text field is
///   intentionally compact; a Mon 11–14, 17–22 lunch/dinner split is
///   reported as `Mon 11:00–14:00`).
/// - `24/7` standalone — all days open 24h.
/// - `off` keyword to mark a day closed (which we omit from output).
///
/// We deliberately ignore the long tail (`PH`, `SH`, month-name date
/// ranges, week numbers, sunrise/sunset, comments, `easter`, year
/// specifications). These are exceedingly rare on restaurant nodes
/// and adding them would balloon the parser well past the value it
/// provides. Anything we can't parse falls back to passing the raw
/// OSM string through unchanged — the user still sees readable hours,
/// just in OSM's native form.
enum OSMOpeningHoursParser {

    /// Parse an OSM `opening_hours` value into a human-readable string
    /// in the same compact form the JSON-LD path produces (e.g.
    /// `"Mon–Fri 11:00–22:00, Sat–Sun 09:00–23:00"`). Returns nil for
    /// empty or unparseable input.
    ///
    /// Earlier versions returned the raw string on parse failure so
    /// the user "still saw the upstream data," but that path let raw
    /// OSM grammar (`Mo`, `Tu`, hyphenated times) leak into the
    /// `hours` column where the display layer couldn't render it.
    /// The new contract is simpler: this parser only emits our
    /// format. The caller decides what to do when nothing comes back
    /// — enrichment writes nothing; the display layer has its own
    /// secondary fallback that tries this parser before giving up.
    ///
    /// **Comma-as-rule-separator**: strict OSM uses `;` between rules
    /// and reserves `,` for multi-window within a day (`Mo 09:00-15:00,
    /// 17:00-19:00`). Real-world data routinely uses `,` between
    /// distinct day-time pairs instead (`Mo 09:00-15:00, Mo 17:00-
    /// 19:00, Tu 09:00-15:00, …`). We normalize the second shape into
    /// the first by promoting any `,` that's immediately followed by
    /// a day-name token (`Mo`, `Tu`, …, `PH`, `SH`) into a `;` so the
    /// downstream split treats each day-time pair as its own rule.
    ///
    /// **Multi-window accumulation**: when the same day appears in
    /// multiple rules (lunch + dinner shifts), we accumulate windows
    /// rather than letting the later rule overwrite the earlier
    /// one. The output uses the multi-window
    /// `WeekdayHoursFormatter.compress([Int:[String]])` overload,
    /// which emits `Mon–Sun 09:00–15:00, 17:00–19:00` for a
    /// uniform lunch-then-dinner week.
    static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "24/7" {
            var byDay: [Int: [String]] = [:]
            for d in 0..<7 { byDay[d] = ["open 24h"] }
            return WeekdayHoursFormatter.compress(byDay)
        }

        var byDay: [Int: [String]] = [:]
        var sawAnyRule = false

        // OSM rule separator. Spec also allows `||` for fallback rules,
        // but those are vanishingly rare on amenity nodes; we treat
        // them like `;` so the second branch becomes a no-op override.
        let normalized = normalizeCommaRuleSeparators(
            trimmed.replacingOccurrences(of: "||", with: ";")
        )
        let rules = normalized
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for rule in rules where !rule.isEmpty {
            guard let parsed = parseRule(rule) else { return nil }
            sawAnyRule = true
            switch parsed {
            case .open(let days, let label):
                for d in days {
                    // Accumulate; same-day rules add windows in
                    // first-seen order. Dedup so a duplicate rule
                    // doesn't render the window twice.
                    if !(byDay[d, default: []].contains(label)) {
                        byDay[d, default: []].append(label)
                    }
                }
            case .closed(let days):
                for d in days { byDay.removeValue(forKey: d) }
            }
        }

        guard sawAnyRule else { return nil }
        // A rule that closes every day (`Mo-Su off`) compresses to an
        // empty string — fall back to a textual marker rather than
        // returning "" which the apply step would skip.
        if byDay.isEmpty { return "Closed" }
        return WeekdayHoursFormatter.compress(byDay)
    }

    /// Regex that matches a comma followed by optional whitespace and
    /// a day-spec, where the comma is itself preceded by a digit (end
    /// of the previous rule's time spec).
    ///
    /// The lookbehind is essential: without it, `Mo,We,Fr 18:00-22:00`
    /// would be mis-split into `Mo; We,Fr 18:00-22:00` because the
    /// regex would match the `,We` inside the day-list. With the
    /// lookbehind requiring a digit before the comma, only commas
    /// that follow a time-spec (like `…-19:00, Mo …`) get promoted to
    /// semicolons.
    private static let commaBeforeDayRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<=\d),\s*((?:Mo|Tu|We|Th|Fr|Sa|Su|PH|SH)(?:[-,](?:Mo|Tu|We|Th|Fr|Sa|Su|PH|SH))*)\s+"#,
            options: []
        )
    }()

    /// Pre-pass regex: a comma that follows `off` or `closed`. NSRegularExpression
    /// requires fixed-length lookbehinds — `(?<=\d|off|closed)` won't
    /// compile. We handle the off/closed case separately by promoting
    /// the comma to a semicolon directly (the day-spec lookahead below
    /// then takes care of the rest of the splitting).
    ///
    /// Without this, an input like `Mo off, Tu-Sa 11:00-21:00, Su off`
    /// stays as a single rule because the comma after `off` is preceded
    /// by a letter — the digit-only lookbehind misses it. The whole
    /// parse then bails, and the table cell would render the raw OSM
    /// instead of the user's actual "Closed today" status.
    private static let offBeforeCommaRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(off|closed)\s*,\s*"#,
            options: [.caseInsensitive]
        )
    }()

    private static func normalizeCommaRuleSeparators(_ input: String) -> String {
        // First: collapse `off,` / `closed,` into `off;` / `closed;`.
        // This is independent of the day-spec lookahead — closing
        // rules don't have a time after them, so the digit-comma
        // regex below would never catch this case on its own.
        let pre = input as NSString
        let withoutOffCommas = offBeforeCommaRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: NSRange(location: 0, length: pre.length),
            withTemplate: "$1; "
        )
        // Second: the digit-comma promotion that handles `…-21:00, Tu …`.
        let mid = withoutOffCommas as NSString
        return commaBeforeDayRegex.stringByReplacingMatches(
            in: withoutOffCommas,
            options: [],
            range: NSRange(location: 0, length: mid.length),
            withTemplate: "; $1 "
        )
    }

    // MARK: - Rule parsing

    /// The two shapes a single OSM rule can take: open over a set of
    /// days with a time-of-day label, or closed (`off`/`closed`) over
    /// a set of days. Returning a sum type keeps the closed case from
    /// being silently swallowed by Swift's `[K: V?]` collapse behavior.
    private enum RuleResult {
        case open(days: Set<Int>, label: String)
        case closed(days: Set<Int>)
    }

    private static func parseRule(_ rule: String) -> RuleResult? {
        // Strip inline comments: `Mo-Fr 09:00-17:00 "by appointment"` etc.
        let stripped = rule.replacingOccurrences(of: "\"[^\"]*\"", with: "",
                                                 options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // After comment-stripping the rule may be empty — that's a
        // no-op, not a parse failure.
        guard !stripped.isEmpty else { return .closed(days: []) }

        // Split day-spec from time-spec. Day specs never contain
        // spaces; time specs can ("9:00 - 17:00") so we re-tighten
        // inside `parseTimeSpec`.
        let (dayPart, timePart) = splitDayAndTime(stripped)
        let days = parseDaySpec(dayPart) ?? Set(0..<7)  // bare time → every day

        if timePart.lowercased() == "off" || timePart.lowercased() == "closed" {
            return .closed(days: days)
        }
        guard let label = parseTimeSpec(timePart) else { return nil }
        return .open(days: days, label: label)
    }

    /// Walk the rule character-by-character looking for the first
    /// non-day token. Days are alphabetic (`Mo`/`Tu`/…), digits inside
    /// a day part show up as week numbers or holidays (out of scope),
    /// so the rule "ends" when we hit a digit or sentinel keyword.
    private static func splitDayAndTime(_ rule: String) -> (String, String) {
        // Day spec ends at the first whitespace boundary, OR if there's
        // no leading day token at all, the entire rule is the time.
        if let firstChar = rule.first, firstChar.isNumber {
            return ("", rule)
        }
        if rule.lowercased() == "off" || rule.lowercased() == "closed" {
            return ("", rule)
        }
        // Look for `<dayspec> <timespec>` shape — first whitespace run
        // that's followed by a digit or `off`.
        var i = rule.startIndex
        while i < rule.endIndex {
            if rule[i].isWhitespace {
                let after = rule.index(after: i)
                guard after < rule.endIndex else { break }
                let next = rule[after]
                if next.isNumber || rule[after...].lowercased().hasPrefix("off")
                    || rule[after...].lowercased().hasPrefix("closed") {
                    let day = rule[..<i].trimmingCharacters(in: .whitespaces)
                    let time = rule[after...].trimmingCharacters(in: .whitespaces)
                    return (day, time)
                }
            }
            i = rule.index(after: i)
        }
        // Fallback: take the whole rule as a day spec, no time. Means
        // we'll bail on `parseTimeSpec("")` below.
        return (rule, "")
    }

    // MARK: - Day spec

    private static let dayIndex: [String: Int] = [
        "mo": 0, "tu": 1, "we": 2, "th": 3,
        "fr": 4, "sa": 5, "su": 6,
    ]

    /// Parse `"Mo-Fr"`, `"Mo,We,Fr"`, `"Mo-Fr,Su"`, `"Mo"`.
    /// Returns nil when the spec contains tokens we don't model.
    private static func parseDaySpec(_ spec: String) -> Set<Int>? {
        let cleaned = spec.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        var out = Set<Int>()
        for piece in cleaned.split(separator: ",") {
            let p = piece.lowercased()
            if let dash = p.firstIndex(of: "-") {
                let lo = String(p[..<dash])
                let hi = String(p[p.index(after: dash)...])
                guard let loIdx = dayIndex[lo], let hiIdx = dayIndex[hi] else { return nil }
                if loIdx <= hiIdx {
                    for d in loIdx...hiIdx { out.insert(d) }
                } else {
                    // Wrap (e.g. `Fr-Mo`): treat as Fr,Sa,Su,Mo.
                    for d in loIdx...6 { out.insert(d) }
                    for d in 0...hiIdx { out.insert(d) }
                }
            } else {
                guard let idx = dayIndex[String(p)] else { return nil }
                out.insert(idx)
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Time spec

    /// Parse the time portion of a rule into a single label. When the
    /// spec contains multiple windows (`11:00-14:00,17:00-22:00`), we
    /// keep only the first — the property is text and consumers want
    /// a glance-readable value, not an exhaustive schedule.
    ///
    /// Returns nil for unparseable input (e.g. `sunrise-sunset`).
    private static func parseTimeSpec(_ spec: String) -> String? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "24/7" { return "open 24h" }
        let firstWindow = trimmed.split(separator: ",")
            .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? trimmed
        // Match HH:MM-HH:MM, tolerating spaces around the dash.
        let pattern = #"^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = firstWindow as NSString
        guard let match = regex.firstMatch(in: firstWindow,
                                           range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let oh = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let om = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let ch = Int(ns.substring(with: match.range(at: 3))) ?? 0
        let cm = Int(ns.substring(with: match.range(at: 4))) ?? 0
        guard (0...24).contains(oh), (0...59).contains(om),
              (0...24).contains(ch), (0...59).contains(cm) else { return nil }
        let opens = String(format: "%02d:%02d", oh, om)
        let closes = String(format: "%02d:%02d", ch, cm)
        return WeekdayHoursFormatter.timeLabel(opens: opens, closes: closes)
    }
}
