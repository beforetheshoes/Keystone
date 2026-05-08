import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.GoogleBooks")

/// Looks up books via the Google Books volumes endpoint. Works without an
/// API key (lower rate limits); keys are consumed when present.
struct GoogleBooksProvider: EnrichmentProvider {
    let databaseKey = "books"
    let triggerPropertyKey = "isbn"

    /// Always available — endpoint works keyless. The API key, if set,
    /// just raises the daily quota.
    func isAvailable() async -> Bool { true }

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
            let (data, urlResponse) = try await URLSession.shared.data(from: url)
            if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("books search status \(http.statusCode)")
                return .unavailable(reason: "HTTP \(http.statusCode)")
            }
            response = try JSONDecoder().decode(GBVolumesResponse.self, from: data)
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

        let coverURL: URL? = {
            let links = info.imageLinks
            for raw in [links?.extraLarge, links?.large, links?.medium, links?.small, links?.thumbnail] {
                if let raw, var components = URLComponents(string: raw) {
                    // Google serves http URLs in the API; coerce to https.
                    if components.scheme == "http" { components.scheme = "https" }
                    if let url = components.url { return url }
                }
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
