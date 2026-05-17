import Foundation

/// Lightweight tag scanner that pulls the few elements we care about out
/// of an HTML document's `<head>`: `<link>` icons, Open Graph image
/// `<meta>` tags, and `<script type="application/ld+json">` payloads.
///
/// Not a full HTML parser — restaurant homepages aren't authored with
/// the same care as browsers expect. We tolerate missing close tags,
/// mixed casing, single-quoted attributes, and stray whitespace, but
/// we don't try to handle truly malformed input. When extraction fails
/// for a particular tag, that tag is silently skipped and the rest of
/// the page continues to be scanned.
enum HTMLHeadExtractor {
    struct Head: Equatable {
        var iconLinks: [IconLink] = []
        var ogImageURLs: [String] = []
        var jsonLDBlocks: [String] = []
        /// `<a href>` URLs whose tag text or href contains a
        /// menu-ish keyword. Restaurant homepages often link to a
        /// specific page on a menu platform (e.g.
        /// `order.spoton.com/so-acme-diner-…/menu`) — the platform's
        /// JSON-LD `hasMenu` typically points to the generic landing
        /// page, so the on-page anchor is the more useful signal.
        var menuLinks: [String] = []
    }

    struct IconLink: Equatable {
        var rel: String           // already lowercased
        var href: String
        var pixelSize: Int?       // parsed from sizes="64x64"
    }

    static func extract(from html: String) -> Head {
        // Only scan up to </head> when present, falling back to the
        // whole document. JSON-LD occasionally appears in <body>, so we
        // run that scan over the full string regardless.
        let headSlice = headSubstring(html) ?? html

        var head = Head()
        head.iconLinks = scanLinks(in: headSlice)
        head.ogImageURLs = scanOGImages(in: headSlice)
        head.jsonLDBlocks = scanJSONLD(in: html)
        head.menuLinks = scanMenuAnchors(in: html)
        return head
    }

    // MARK: - Slicing

    private static func headSubstring(_ html: String) -> String? {
        guard let range = html.range(of: "</head>", options: .caseInsensitive) else { return nil }
        return String(html[..<range.lowerBound])
    }

    // MARK: - Tag scans
    //
    // We compile the regexes lazily on first use rather than at file
    // scope so a static init crash (theoretically impossible with
    // literal patterns, but cheap insurance) doesn't bring down the
    // whole enrichment subsystem.

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"<link\b[^>]*?>"#,
        options: [.caseInsensitive]
    )

    private static let metaRegex = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*?>"#,
        options: [.caseInsensitive]
    )

    private static let scriptLDRegex = try! NSRegularExpression(
        pattern: #"<script\b([^>]*?)>([\s\S]*?)</script>"#,
        options: [.caseInsensitive]
    )

    private static func scanLinks(in html: String) -> [IconLink] {
        let ns = html as NSString
        var out: [IconLink] = []
        linkRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let tag = ns.substring(with: match.range)
            let attrs = parseAttributes(tag)
            guard let rel = attrs["rel"]?.lowercased(), rel.contains("icon"),
                  let href = attrs["href"], !href.isEmpty else { return }
            let size = parsePixelSize(attrs["sizes"])
            out.append(IconLink(rel: rel, href: href, pixelSize: size))
        }
        return out
    }

    private static func scanOGImages(in html: String) -> [String] {
        let ns = html as NSString
        var out: [String] = []
        metaRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let tag = ns.substring(with: match.range)
            let attrs = parseAttributes(tag)
            let property = (attrs["property"] ?? attrs["name"])?.lowercased()
            guard property == "og:image" || property == "og:image:url" || property == "og:image:secure_url",
                  let content = attrs["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return }
            out.append(content)
        }
        return out
    }

    private static func scanJSONLD(in html: String) -> [String] {
        let ns = html as NSString
        var out: [String] = []
        scriptLDRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let attrTextRange = match.range(at: 1)
            let bodyRange = match.range(at: 2)
            let attrText = ns.substring(with: attrTextRange)
            // Cheap type check that doesn't require a full attribute parse.
            guard attrText.range(of: "application/ld+json", options: .caseInsensitive) != nil else { return }
            let body = ns.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            out.append(body)
        }
        return out
    }

    // MARK: - Anchor / menu-link scan

    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"<a\b([^>]*?)>([\s\S]*?)</a>"#,
        options: [.caseInsensitive]
    )

    /// Keywords (lowercased) that mark an anchor as menu-ish. We look
    /// at both the visible link text and the URL itself — restaurants
    /// commonly use either "Menu" / "Order online" as the visible
    /// text or paths like `/menu`, `/order`, on platform domains.
    private static let menuKeywords: [String] = [
        "menu", "order online", "order now", "view menu",
        "see menu", "our menu", "lunch menu", "dinner menu",
    ]

    /// Known menu-platform host fragments. An anchor that links to
    /// one of these is always a menu link regardless of its visible
    /// text — useful when a restaurant uses an iconic button with no
    /// readable label.
    private static let menuPlatformHosts: [String] = [
        "spoton.com", "order.spoton.com", "toasttab.com", "order.toasttab.com",
        "doordash.com", "ubereats.com", "grubhub.com", "seamless.com",
        "chownow.com", "menufy.com", "bentobox", "bbot.menu",
        "popmenu.com", "squareonline.com", "square.site", "clover.com",
    ]

    private static func scanMenuAnchors(in html: String) -> [String] {
        let ns = html as NSString
        var hits: [(href: String, score: Int)] = []
        anchorRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            let attrs = parseAttributes("<a " + ns.substring(with: match.range(at: 1)) + ">")
            guard let href = attrs["href"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty,
                  !href.hasPrefix("#"),
                  !href.hasPrefix("javascript:")
            else { return }
            let rawText = ns.substring(with: match.range(at: 2))
            let visibleText = rawText.replacingOccurrences(
                of: "<[^>]+>", with: " ", options: .regularExpression
            ).lowercased()
            let hrefLower = href.lowercased()

            let textHit = menuKeywords.contains { visibleText.contains($0) }
            let hostHit = menuPlatformHosts.contains { hrefLower.contains($0) }
            let pathHit = hrefLower.contains("/menu") || hrefLower.contains("/order")

            guard textHit || hostHit || pathHit else { return }
            // Score by specificity. Longer paths beat shorter ones —
            // `/so-acme-diner-7827/mebane-nc/BL-9561-…` outranks the
            // generic `/menu`. Host-platform hits get a small bonus
            // so a platform-specific link wins over a same-site
            // `/menu` page when both are present.
            var score = hrefLower.split(separator: "/").count * 10
            if hostHit { score += 25 }
            if textHit { score += 5 }
            hits.append((href, score))
        }
        // Stable sort by descending score, deduped on absolute URL.
        var seen = Set<String>()
        return hits
            .sorted(by: { $0.score > $1.score })
            .compactMap { $0.href }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Attribute parser

    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
        options: []
    )

    /// Parse the attributes off a tag like `<link rel="icon" href="...">`.
    /// Keys are lowercased; values are returned verbatim (no HTML-entity
    /// decoding beyond what icon hrefs need — `&amp;` is the only one
    /// we observe in real-world href values).
    private static func parseAttributes(_ tag: String) -> [String: String] {
        let ns = tag as NSString
        var out: [String: String] = [:]
        attributeRegex.enumerateMatches(in: tag, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            for i in 2...4 {
                let r = match.range(at: i)
                if r.location != NSNotFound {
                    value = ns.substring(with: r)
                    break
                }
            }
            out[name] = value.replacingOccurrences(of: "&amp;", with: "&")
        }
        return out
    }

    private static func parsePixelSize(_ value: String?) -> Int? {
        guard let value = value?.lowercased() else { return nil }
        // `sizes` can be "64x64", "16x16 32x32", "any". Take the max
        // numeric width we can find.
        var max: Int = 0
        let parts = value.split(whereSeparator: { !$0.isNumber && $0 != "x" })
        for part in parts {
            let dims = part.split(separator: "x")
            if let n = Int(dims.first ?? "") { max = Swift.max(max, n) }
        }
        return max > 0 ? max : nil
    }
}
