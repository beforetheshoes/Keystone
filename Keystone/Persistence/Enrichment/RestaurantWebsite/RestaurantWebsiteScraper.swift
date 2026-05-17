import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.RestaurantWebsite")

/// Best-effort enrichment data pulled from a restaurant's own website.
/// Every field is optional — a missing logo or empty JSON-LD doesn't
/// invalidate the rest, and the provider applies whatever's present.
struct RestaurantScrapeResult: Equatable, Sendable {
    /// Validated logo image. `data` is the raw image bytes; `fileExtension`
    /// is a best-guess based on the URL or magic-byte detection.
    var logo: LogoFile?
    /// Schema.org JSON-LD findings: hours, rating, price band, menu URL.
    var parsed: SchemaOrgLDParser.Parsed
    /// Menu URL fallback discovered by probing `/menu` when JSON-LD
    /// didn't carry one. Only set when `parsed.menuURL` is nil.
    var probedMenuURL: URL?

    struct LogoFile: Equatable, Sendable {
        var data: Data
        var fileExtension: String
    }
}

/// Network surface for the scraper. Production wires `LiveScrapingHTTP`;
/// tests inject `StubScrapingHTTP` with canned responses.
protocol RestaurantScrapingHTTP: Sendable {
    /// Fetch HTML at `url`. Returns the decoded body and the URL the
    /// session ended up at (after redirects) — needed when resolving
    /// relative links from the document head. Returns nil on any
    /// network or decode failure.
    func fetchHTML(_ url: URL) async -> (html: String, finalURL: URL)?

    /// Fetch raw bytes (e.g. an image) at `url`. Returns nil on failure
    /// or non-2xx status. Caller is responsible for content validation.
    func fetchBytes(_ url: URL) async -> Data?

    /// Probe whether `url` resolves to HTML (HEAD-style, but we GET it
    /// because some sites 405 on HEAD). Returns true when the response
    /// is 2xx and content-type starts with `text/html`.
    func probeHTML(_ url: URL) async -> Bool
}

/// Orchestrates the website fetch → logo + JSON-LD extraction → menu
/// probe pipeline. Pure on top of `RestaurantScrapingHTTP` so tests can
/// drive it with fixtures without hitting the network.
struct RestaurantWebsiteScraper: Sendable {
    var http: any RestaurantScrapingHTTP

    static let live = RestaurantWebsiteScraper(http: LiveScrapingHTTP())

    /// Fetch + parse + extract. Always returns a value; missing fields
    /// stay nil. The caller writes the marker timestamp regardless of
    /// what comes back so we don't loop on dead-end restaurants.
    func scrape(websiteURL rawURL: URL) async -> RestaurantScrapeResult {
        guard let normalized = normalizeHTTPS(rawURL) else {
            return RestaurantScrapeResult(parsed: .init())
        }

        guard let page = await http.fetchHTML(normalized) else {
            log.info("fetch failed for \(rawURL.absoluteString, privacy: .public)")
            return RestaurantScrapeResult(parsed: .init())
        }

        let head = HTMLHeadExtractor.extract(from: page.html)
        var parsed = SchemaOrgLDParser.parse(jsonStrings: head.jsonLDBlocks)
        let logo = await pickLogo(head: head, baseURL: page.finalURL)

        // Prefer specific menu links lifted from the body's `<a>`
        // tags over JSON-LD's `hasMenu`. Restaurant homepages on
        // platforms like SpotOn / Toast / DoorDash link to the
        // restaurant-specific URL (e.g. `…/so-acme-diner-7827/menu`)
        // via a visible "Menu" button, while the JSON-LD payload
        // often emits the platform's generic landing page
        // (`order.spoton.com/menu`). Take the highest-scoring body
        // anchor when present and override `parsed.menuURL` so the
        // user sees the page they'd actually want.
        let bodyMenu = bestBodyMenuLink(head.menuLinks, baseURL: page.finalURL)
        if let bodyMenu {
            parsed.menuURL = bodyMenu
        }

        let probedMenu = parsed.menuURL == nil ? await probeMenu(baseURL: page.finalURL) : nil
        return RestaurantScrapeResult(logo: logo, parsed: parsed, probedMenuURL: probedMenu)
    }

    /// Resolve the head extractor's already-ranked menu-link list to
    /// the best absolute URL. The list is sorted by specificity, so we
    /// just take the first one we can normalize to an HTTPS URL.
    private func bestBodyMenuLink(_ rawLinks: [String], baseURL: URL) -> URL? {
        for raw in rawLinks {
            guard let url = resolve(raw, base: baseURL) else { continue }
            guard let normalized = normalizeHTTPS(url) else { continue }
            return normalized
        }
        return nil
    }

    // MARK: - Logo selection

    /// Try each candidate in priority order until one downloads and
    /// validates. The classic-favicon paths come last as a fallback
    /// for sites that don't declare any `<link>` icons at all.
    private func pickLogo(head: HTMLHeadExtractor.Head, baseURL: URL) async -> RestaurantScrapeResult.LogoFile? {
        let candidates = orderedLogoCandidates(head: head, baseURL: baseURL)
        for candidate in candidates {
            guard let bytes = await http.fetchBytes(candidate) else { continue }
            guard let ext = validateImage(bytes, url: candidate) else { continue }
            return .init(data: bytes, fileExtension: ext)
        }
        return nil
    }

    private func orderedLogoCandidates(head: HTMLHeadExtractor.Head, baseURL: URL) -> [URL] {
        var ordered: [URL] = []
        var seen = Set<String>()
        func push(_ url: URL?) {
            guard let url else { return }
            if seen.insert(url.absoluteString).inserted { ordered.append(url) }
        }

        // 1. Apple touch icons — precomposed first, then plain.
        for icon in head.iconLinks where icon.rel.contains("apple-touch-icon-precomposed") {
            push(resolve(icon.href, base: baseURL))
        }
        for icon in head.iconLinks where icon.rel.contains("apple-touch-icon") && !icon.rel.contains("precomposed") {
            push(resolve(icon.href, base: baseURL))
        }
        // 2. Generic icons / shortcut icons — largest first.
        let regular = head.iconLinks.filter { icon in
            icon.rel.contains("icon") && !icon.rel.contains("apple-touch-icon")
        }.sorted { ($0.pixelSize ?? 0) > ($1.pixelSize ?? 0) }
        for icon in regular {
            push(resolve(icon.href, base: baseURL))
        }
        // 3. Open Graph image.
        for url in head.ogImageURLs {
            push(resolve(url, base: baseURL))
        }
        // 4. Well-known paths.
        push(baseURL.deletingLastPathComponent().standardizedFileURL == baseURL.standardizedFileURL
             ? URL(string: "/apple-touch-icon.png", relativeTo: baseURL)?.absoluteURL
             : URL(string: "/apple-touch-icon.png", relativeTo: baseURL)?.absoluteURL)
        push(URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL)
        return ordered
    }

    /// Returns a best-guess file extension if `data` looks like a valid
    /// image and is at least 1KB, else nil. The 1KB floor rejects
    /// near-empty responses and broken-image placeholders without
    /// punishing legitimate SVGs, which we also accept above 200 bytes.
    private func validateImage(_ data: Data, url: URL) -> String? {
        if let ext = magicByteExtension(data), data.count >= 1024 {
            return ext
        }
        // SVG is text and tends to be small; allow a lower floor.
        if isSVG(data), data.count >= 200 {
            return "svg"
        }
        return nil
    }

    private func magicByteExtension(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF])       { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.count >= 12,
           b.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        if b.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }
        return nil
    }

    private func isSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(256), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return head.hasPrefix("<svg") || head.hasPrefix("<?xml")
    }

    // MARK: - Menu probe

    private func probeMenu(baseURL: URL) async -> URL? {
        for path in ["/menu", "/menus", "/food"] {
            guard let candidate = URL(string: path, relativeTo: baseURL)?.absoluteURL else { continue }
            if await http.probeHTML(candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - URL helpers

    private func normalizeHTTPS(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.scheme == "http" {
            components.scheme = "https"
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else { return nil }
        return components.url
    }

    private func resolve(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}

// MARK: - Live HTTP

/// Production `RestaurantScrapingHTTP`. Uses `URLSession.shared` with
/// short timeouts so a slow restaurant site doesn't stall the whole
/// background enrichment pass.
struct LiveScrapingHTTP: RestaurantScrapingHTTP {
    func fetchHTML(_ url: URL) async -> (html: String, finalURL: URL)? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("text/html, */*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            // Try the charset advertised by the server, then fall back to
            // UTF-8 then Latin-1. Restaurant sites span the encoding zoo.
            if let html = decode(data: data, response: http) {
                return (html, http.url ?? url)
            }
            return nil
        } catch {
            return nil
        }
    }

    func fetchBytes(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("image/*, */*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func probeHTML(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            return contentType.contains("text/html")
        } catch {
            return false
        }
    }

    private func decode(data: Data, response: HTTPURLResponse) -> String? {
        if let charset = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .components(separatedBy: "charset=")
            .dropFirst().first?
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespaces),
           !charset.isEmpty {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let s = String(data: data, encoding: String.Encoding(rawValue: nsEnc)) {
                    return s
                }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
