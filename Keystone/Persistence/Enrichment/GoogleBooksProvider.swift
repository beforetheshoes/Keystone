import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.GoogleBooks")

/// Looks up books via the Google Books volumes endpoint. Works without an
/// API key (lower rate limits); keys are consumed when present.
struct GoogleBooksProvider: EnrichmentProvider, LookupProvider {
    let databaseKey = "books"
    let triggerPropertyKey = "isbn"

    /// Always available — endpoint works keyless. The API key, if set,
    /// just raises the daily quota.
    func isAvailable() async -> Bool { true }

    func searchCandidates(query: String) async -> [LookupCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q",          value: trimmed),
            URLQueryItem(name: "maxResults", value: "10"),
        ]
        if let apiKey = APIKeys.get(.googleBooks), !apiKey.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "key", value: apiKey))
        }
        guard let url = components.url else { return [] }

        let response: GBVolumesResponse
        do {
            response = try await GoogleBooksHTTP.fetchWithRetry(url: url)
        } catch {
            log.error("books search \(error.localizedDescription, privacy: .public)")
            return []
        }

        return (response.items ?? []).compactMap { volume in
            guard let apply = Self.apply(from: volume) else { return nil }
            let info = volume.volumeInfo
            let subtitleParts: [String?] = [
                info.authors?.joined(separator: ", "),
                info.publishedDate.flatMap { String($0.prefix(4)) },
            ]
            let subtitle = subtitleParts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return LookupCandidate(
                id: volume.id,
                title: info.title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                coverURL: apply.coverImageURL,
                apply: apply
            )
        }
    }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .notFound }
        let author = record.propertyValues["author"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var queryParts = ["intitle:\(title)"]
        if let author, !author.isEmpty { queryParts.append("inauthor:\(author)") }
        let query = queryParts.joined(separator: "+")

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q",          value: query),
            URLQueryItem(name: "maxResults", value: "5"),
        ]
        if let apiKey = APIKeys.get(.googleBooks), !apiKey.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "key", value: apiKey))
        }
        guard let url = components.url else { return .notFound }

        let response: GBVolumesResponse
        do {
            response = try await GoogleBooksHTTP.fetchWithRetry(url: url)
        } catch GoogleBooksHTTP.HTTPError.status(let code) {
            log.error("books search status \(code)")
            return .unavailable(reason: "HTTP \(code)")
        } catch {
            log.error("books search \(error.localizedDescription, privacy: .public)")
            return .notFound
        }

        let items = response.items ?? []
        guard let top = items.first else { return .notFound }

        // Confidence: case-insensitive title match (allowing trailing words).
        let topTitle = top.volumeInfo.title.lowercased()
        let wanted = title.lowercased()
        let confident = topTitle == wanted || topTitle.hasPrefix(wanted)
        if confident, let apply = Self.apply(from: top) {
            return .resolved(apply)
        }
        let candidates = items.prefix(5).compactMap(Self.apply(from:))
        return candidates.isEmpty ? .notFound : .ambiguous(Array(candidates))
    }

    /// Build an `EnrichmentApply` from a Google Books volume entry. Returns
    /// nil only when there's no ISBN (without it the trigger-property gate
    /// can't close, so the next pass would re-pick the same record).
    private static func apply(from item: GBVolume) -> EnrichmentApply? {
        var updates: [String: String] = [:]
        let info = item.volumeInfo

        // Prefer ISBN_13, fall back to ISBN_10.
        let isbn = info.industryIdentifiers?.first(where: { $0.type == "ISBN_13" })?.identifier
            ?? info.industryIdentifiers?.first(where: { $0.type == "ISBN_10" })?.identifier
        guard let isbn, !isbn.isEmpty else { return nil }
        updates["isbn"] = isbn

        if let publisher = info.publisher, !publisher.isEmpty {
            updates["publisher"] = publisher
        }
        if let date = info.publishedDate, !date.isEmpty {
            updates["published_date"] = date
        }
        if let pages = info.pageCount, pages > 0 {
            updates["page_count"] = String(pages)
        }
        if let authors = info.authors, !authors.isEmpty {
            // Don't overwrite an author the user already typed; the
            // service's blanks-only write logic enforces that. But if the
            // record's author was blank, plug it in.
            updates["author"] = authors.joined(separator: ", ")
        }
        if let desc = info.description, !desc.isEmpty {
            updates["description"] = desc
        }
        if let cats = info.categories, !cats.isEmpty {
            // Google Books categories are slash-delimited paths like
            // "Fiction / Mystery & Detective / Cozy". Flatten the leaf
            // segments into a single de-duped multiSelect set.
            let flat = cats.flatMap { $0.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) } }
            let encoded = MultiSelectValue.encode(flat)
            if !encoded.isEmpty { updates["tags"] = encoded }
        }

        let coverURL: URL? = {
            let links = info.imageLinks
            for raw in [links?.extraLarge, links?.large, links?.medium, links?.small, links?.thumbnail] {
                if let raw, let url = upgradeCoverURL(raw) { return url }
            }
            return nil
        }()

        let preview = info.authors?.first.map { "\(info.title) — \($0)" } ?? info.title
        return EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: coverURL,
            previewLabel: preview
        )
    }
}

// MARK: - HTTP helper

/// Shared retry-on-429/503 fetcher for Google Books calls. Lives in
/// this file because the response shape is private — both the full
/// `GoogleBooksProvider` (enrichment + lookup-creation search) and
/// the `GoogleBooksCoverProvider` (cover-only picker) go through here
/// so a quota event in one path doesn't blow the same call in another.
enum GoogleBooksHTTP {
    enum HTTPError: Error {
        case status(Int)
    }

    /// 3 attempts with exponential backoff (200ms → 400ms → 800ms) on
    /// 429 / 503. Anything else throws immediately. The retries are
    /// per-call so a momentary quota burst (e.g. background enrichment
    /// hammering the API) doesn't make every interactive search fail.
    static func fetchWithRetry<T: Decodable>(url: URL) async throws -> T {
        var delayMs: UInt64 = 200
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) {
                        return try JSONDecoder().decode(T.self, from: data)
                    }
                    if http.statusCode == 429 || http.statusCode == 503 {
                        lastError = HTTPError.status(http.statusCode)
                        if attempt < 2 {
                            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                            delayMs *= 2
                            continue
                        }
                    }
                    throw HTTPError.status(http.statusCode)
                }
                throw URLError(.badServerResponse)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs *= 2
                    continue
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}

// MARK: - Cover URL upgrade

/// Google Books normally hands the API back a tiny `thumbnail` URL even
/// when a sharper image exists — the higher-res variants are licensed
/// separately. Two well-known query-param tweaks return a noticeably
/// crisper image from the same volume id:
///
/// - **Drop `edge=curl`**: removes the fake page-curl decoration that
///   Google bakes into the default thumbnail.
/// - **`zoom=0`**: Google's content endpoint treats 0 as "send the
///   largest available", versus the default of `zoom=1` (~128px).
///
/// Also coerces `http` → `https` (the API still emits insecure URLs).
/// Returns nil only when the input doesn't parse as a URL at all.
private func upgradeCoverURL(_ raw: String) -> URL? {
    guard var components = URLComponents(string: raw) else { return nil }
    if components.scheme == "http" { components.scheme = "https" }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "edge" }
    if let zoomIdx = items.firstIndex(where: { $0.name == "zoom" }) {
        items[zoomIdx].value = "0"
    } else {
        items.append(URLQueryItem(name: "zoom", value: "0"))
    }
    components.queryItems = items.isEmpty ? nil : items
    return components.url
}

// MARK: - Response shape

/// Minimal subset of the Google Books v1 response. Decoded fields are
/// strictly what the provider reads; unknown keys are ignored.
private struct GBVolumesResponse: Decodable {
    let items: [GBVolume]?
}

private struct GBVolume: Decodable {
    let id: String
    let volumeInfo: GBVolumeInfo
}

private struct GBVolumeInfo: Decodable {
    let title: String
    let authors: [String]?
    let publisher: String?
    let publishedDate: String?
    let pageCount: Int?
    let industryIdentifiers: [GBIndustryIdentifier]?
    let imageLinks: GBImageLinks?
    let description: String?
    let categories: [String]?
}

private struct GBIndustryIdentifier: Decodable {
    let type: String
    let identifier: String
}

private struct GBImageLinks: Decodable {
    let smallThumbnail: String?
    let thumbnail: String?
    let small: String?
    let medium: String?
    let large: String?
    let extraLarge: String?
}
