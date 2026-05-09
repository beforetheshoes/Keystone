import Foundation

/// Heuristic field extraction for the LLM-transcribed sidecar bodies in
/// `Cars/<vehicle>/<date>/*.pdf-processed-markdown.md`. The transcripts
/// follow a few recurring shapes — header table with vendor name,
/// "Mileage:" lines, "Invoice Total" / "TOTAL" lines — but no single
/// pattern matches all 100 files. Each field returns `nil` when no
/// confident match is found; the backfill orchestrator surfaces those
/// in a per-file report so the user can hand-tag what we miss.
///
/// All regexes here run against the body *with* leading/trailing
/// markdown formatting (`**`, `*`, `#`, bullets) so the patterns can
/// anchor on the bold/italic conventions the transcripts share.
enum InvoiceExtraction {
    struct Extracted {
        var vendor: String?
        var mileage: Int?
        var cost: Double?
    }

    static func extract(from body: String) -> Extracted {
        var out = Extracted()
        // Vendor patterns lean on `**bold**` as a structural anchor, so
        // they need the raw body. Mileage / cost are looser key-value
        // matches and benefit from a cleaned view that has the bold
        // markers and stray markdown punctuation flattened out.
        out.vendor = extractVendor(body)
        let cleaned = body
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
        out.mileage = extractMileage(cleaned)
        out.cost = extractCost(cleaned)
        return out
    }

    // MARK: - Vendor

    /// Vendor candidates the transcripts use, ordered by RELIABILITY
    /// of the signal. Chain-shop names (Take 5, Jiffy Lube, etc.) and
    /// "<Dealer> Honda" get priority over the first bold header line
    /// because LLM transcripts sometimes mangle the receipt's stylized
    /// title (e.g. a Take 5 invoice transcribes as `**AKE S OIL
    /// CHANGE**`, dropping the leading T). The full chain name elsewhere
    /// in the body is the more trustworthy anchor.
    static func extractVendor(_ body: String) -> String? {
        // 1) Chain-shop names — most reliable. Match anywhere in body.
        if let m = match(body, pattern: #"\b(TAKE\s*5\s*OIL\s*CHANGE(?:\s*#\s*\d+)?|JIFFY\s*LUBE(?:\s*#\s*\d+)?|VALVOLINE\b[^\n]*|MIDAS\b[^\n]*|GREASE\s*MONKEY\b[^\n]*|FIRESTONE\b[^\n]*)"#) {
            return sanitizeVendor(m)
        }

        // 2) "<dealer> Honda" / Toyota / Subaru etc. — searched on a
        //    cleaned copy without bold markers so `**East Coast
        //    Honda**` is reachable.
        let cleaned = body.replacingOccurrences(of: "*", with: "")
        if let m = match(cleaned, pattern: #"\b([A-Z][A-Za-z'\-]+(?:\s+[A-Z][A-Za-z'\-]+){0,3}\s+(?:Honda|Toyota|Ford|Chevrolet|GMC|Subaru|Acura|Nissan|Mazda|Hyundai|Kia))\b"#) {
            return sanitizeVendor(m)
        }

        // 3) Bold-wrapped or heading line near the top, only as a
        //    last-resort anchor and only when it doesn't look like a
        //    mangled fragment (must be 3+ words OR contain an obvious
        //    vendor keyword).
        let lines = body.components(separatedBy: "\n").prefix(40)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[scan]") { continue }
            if let captured = match(line, pattern: #"^\*\*([A-Z][A-Z0-9 &\-'\.\#\,]+)\*\*\s*$"#) {
                if looksLikeVendor(captured) {
                    return sanitizeVendor(captured)
                }
            }
            if let captured = match(line, pattern: #"^#{1,6}\s+([A-Z][A-Za-z0-9 &\-'\.]+?)(?:\s+(?:Service\s+)?Invoice|\s+Receipt)?\s*$"#) {
                if looksLikeVendor(captured) {
                    return sanitizeVendor(captured)
                }
            }
        }

        return nil
    }

    /// Heuristic gate to reject obvious junk in the bold-header
    /// fallback path. Multi-word names are treated as plausible; a
    /// single odd token like "AKE S OIL CHANGE" (3 words but
    /// suspicious) gets rejected only if it doesn't contain a vendor
    /// keyword. Conservative rather than aggressive — false negatives
    /// are easier to recover from than false positives.
    private static func looksLikeVendor(_ candidate: String) -> Bool {
        let stripped = candidate.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        let wordCount = stripped.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount >= 3 { return true }
        let keywords = ["honda", "toyota", "ford", "chevrolet", "gmc", "subaru",
                        "acura", "nissan", "mazda", "hyundai", "kia",
                        "auto", "tire", "service", "lube", "oil"]
        let lower = stripped.lowercased()
        return keywords.contains(where: { lower.contains($0) })
    }

    private static func sanitizeVendor(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip residual formatting characters and the trailing
        // " Service Invoice" / " Receipt" suffix so the canonicalized
        // value matches across variants of the same shop.
        for token in [" Service Invoice", " Invoice", " Receipt", " — Receipt"] {
            if s.hasSuffix(token) { s = String(s.dropLast(token.count)) }
        }
        s = s.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Title-case ALL CAPS receipts so "TAKE 5 OIL CHANGE" becomes
        // "Take 5 Oil Change" — friendlier for the vendors database.
        if s == s.uppercased() && s.count > 4 {
            s = titleCase(s)
        }
        return s
    }

    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if ["of", "and", "the"].contains(lower), word != s.split(separator: " ").first {
                return lower
            }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Mileage

    /// Pulls an integer mileage out of body text. Patterns in order of
    /// preference:
    ///   - "Present Mileage: 36,696"  (Take 5 receipts)
    ///   - "| Mileage              | 6,393                     |" (table cells)
    ///   - "Mileage: 41417" / "Mileage 41,417 mi" (free-form)
    ///   - "Odometer: 99,234"
    static func extractMileage(_ body: String) -> Int? {
        let patterns = [
            #"(?i)Present\s+Mileage[^\d]{0,8}([\d,]+)"#,
            #"(?i)\|\s*Mileage\s*\|\s*([\d,]+)\s*\|"#,
            #"(?i)Mileage\s*[:\-]?\s*([\d,]+)"#,
            #"(?i)Odometer\s*[:\-]?\s*([\d,]+)"#,
            #"(?i)\b([\d,]{4,7})\s*(?:miles|mi)\b"#,
        ]
        var best: Int? = nil
        for pattern in patterns {
            if let captured = match(body, pattern: pattern) {
                let cleaned = captured.replacingOccurrences(of: ",", with: "")
                if let n = Int(cleaned), n > 0, n < 1_000_000 {
                    // Prefer the FIRST confident match — earlier
                    // patterns are stronger anchors than the bare
                    // "<number> miles" fallback. Once we have any hit,
                    // stop unless the candidate is implausibly small.
                    if best == nil || n > best! { best = n }
                    if pattern == patterns[0] || pattern == patterns[1] { return n }
                }
            }
        }
        return best
    }

    // MARK: - Cost

    /// Pulls the invoice grand total. Patterns in order of preference:
    ///   - "**TOTAL (MASTER CARD)** … **$72.81**"  (Take 5 totals row)
    ///   - "Invoice Total          | $223.45"
    ///   - "Total                   $223.45"  / "Grand Total: $223.45"
    static func extractCost(_ body: String) -> Double? {
        let patterns = [
            #"(?i)\*\*\s*TOTAL[^*]*\*\*\s*[^|$]*[$]?\s*([\d,]+\.\d{2})"#,
            #"(?i)Invoice\s+Total[^\d$]*[$]\s*([\d,]+\.\d{2})"#,
            #"(?i)Grand\s+Total[^\d$]*[$]\s*([\d,]+\.\d{2})"#,
            #"(?i)\bTotal\b[^\d$]*[$]\s*([\d,]+\.\d{2})"#,
            #"(?i)Amount\s+(?:Due|Paid)[^\d$]*[$]\s*([\d,]+\.\d{2})"#,
        ]
        for pattern in patterns {
            if let captured = match(body, pattern: pattern) {
                let cleaned = captured.replacingOccurrences(of: ",", with: "")
                if let d = Double(cleaned), d > 0, d < 100_000 {
                    return d
                }
            }
        }
        return nil
    }

    // MARK: - Regex helper

    /// Run `pattern` against `s` and return the first capture group.
    /// Returns nil for no match or invalid pattern.
    static func match(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let result = regex.firstMatch(in: s, options: [], range: range),
              result.numberOfRanges >= 2,
              let captureRange = Range(result.range(at: 1), in: s) else {
            return nil
        }
        return String(s[captureRange])
    }
}
