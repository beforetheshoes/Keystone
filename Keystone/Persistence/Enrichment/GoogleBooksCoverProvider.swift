import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "CoverProvider.GoogleBooks")

/// Google Books as a cover-only source. Uses a *targeted* query
/// (`intitle:` / `inauthor:`) rather than the freetext search the
/// lookup-creation sheet uses — for known title + author, the
/// operator-scoped query is dramatically more accurate and returns
/// far fewer irrelevant editions. Also picks up the user's API key
/// (Keychain via `APIKeys.get(.googleBooks)`) and retries on
/// 429 / 503 with exponential backoff.
struct GoogleBooksCoverProvider: CoverProvider {
    let databaseKey = "books"
    let sourceLabel = "Google Books"

    func isAvailable() async -> Bool { true }

    func searchCovers(query: String, hints: [String: String]) async throws -> [CoverCandidate] {
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        let author = hints["author"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        // `intitle:"X" inauthor:"Y"` — quoted to keep multi-word
        // phrases intact. The API treats space inside the quoted
        // phrase as part of the operator's argument, and treats
        // the space between operators as logical AND.
        var qParts = ["intitle:\(quoted(title))"]
        if !author.isEmpty {
            qParts.append("inauthor:\(quoted(author))")
        }
        let q = qParts.joined(separator: " ")

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q",          value: q),
            URLQueryItem(name: "maxResults", value: "10"),
            // Restrict to English-language editions — when an English
            // book gets edition-spammed in the index, the search will
            // otherwise surface translations on top.
            URLQueryItem(name: "langRestrict", value: "en"),
            // We only need cover-bearing volumes; the API still
            // returns volumes without imageLinks but `printType=books`
            // narrows out magazine entries that frequently lack covers.
            URLQueryItem(name: "printType",   value: "books"),
        ]
        if let apiKey = APIKeys.get(.googleBooks), !apiKey.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "key", value: apiKey))
        } else {
            log.info("google books: no API key configured — using unauthenticated quota")
        }
        guard let url = components.url else { return [] }

        let response: GBVolumesCoverResponse = try await GoogleBooksHTTP.fetchWithRetry(url: url)
        return (response.items ?? []).compactMap(Self.candidate(from:))
    }

    private static func candidate(from item: GBVolumeCover) -> CoverCandidate? {
        let info = item.volumeInfo
        let coverRaw: String? = {
            // Prefer larger when present — these often exist even when
            // the search response default-renders the small thumbnail.
            return info.imageLinks?.extraLarge
                ?? info.imageLinks?.large
                ?? info.imageLinks?.medium
                ?? info.imageLinks?.thumbnail
                ?? info.imageLinks?.smallThumbnail
        }()
        guard let raw = coverRaw, let url = upgradeCoverURL(raw) else { return nil }
        let subtitleParts: [String] = [
            info.authors?.first ?? "",
            info.publishedDate.map { String($0.prefix(4)) } ?? "",
        ].filter { !$0.isEmpty }
        let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
        return CoverCandidate(
            id: "googlebooks:\(item.id)",
            title: info.title,
            subtitle: subtitle,
            coverURL: url,
            thumbnailURL: url,
            sourceLabel: "Google Books"
        )
    }

    /// `intitle:Cobble Hill` matches differently than
    /// `intitle:"Cobble Hill"` — without quotes Google scopes each
    /// token to `intitle:`, with quotes it's the full phrase. Phrase
    /// search is what we want for known titles.
    private func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\"", with: "")
        return "\"\(escaped)\""
    }
}

/// Mirror of `GoogleBooksProvider.upgradeCoverURL` — extracted here so
/// the cover provider doesn't reach into the other file's private
/// helper. `zoom=0` requests the largest available variant; `edge=curl`
/// removes Google's page-curl decoration baked into thumbnails.
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

/// Cover-only subset of the Google Books `/volumes` response. Distinct
/// from the full lookup struct so each field is justifiable per use
/// site — we ignore description / categories / publisher here because
/// a cover pick doesn't write those.
private struct GBVolumesCoverResponse: Decodable {
    let items: [GBVolumeCover]?
}

private struct GBVolumeCover: Decodable {
    let id: String
    let volumeInfo: GBVolumeCoverInfo
}

private struct GBVolumeCoverInfo: Decodable {
    let title: String
    let authors: [String]?
    let publishedDate: String?
    let imageLinks: GBVolumeCoverImageLinks?
}

private struct GBVolumeCoverImageLinks: Decodable {
    let smallThumbnail: String?
    let thumbnail: String?
    let small: String?
    let medium: String?
    let large: String?
    let extraLarge: String?
}
