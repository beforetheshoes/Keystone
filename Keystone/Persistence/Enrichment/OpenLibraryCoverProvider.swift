import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "CoverProvider.OpenLibrary")

/// Open Library cover search. Keyless — the docs cap unauthenticated
/// callers at 100 requests / 5 min / IP, which is fine for an
/// interactive picker. Each search hit carries an integer `cover_i`;
/// we build large + medium cover URLs from it via the `covers.openlibrary.org`
/// endpoint.
struct OpenLibraryCoverProvider: CoverProvider {
    let databaseKey = "books"
    let sourceLabel = "Open Library"

    func isAvailable() async -> Bool { true }

    func searchCovers(query: String, hints: [String: String]) async throws -> [CoverCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "10"),
            // Trim the response — these are the only fields we read.
            URLQueryItem(
                name: "fields",
                value: "key,title,author_name,cover_i,first_publish_year,isbn"
            ),
        ]
        // If the caller passed an author hint (the record's `author`
        // property), narrow with it. Open Library's `author` parameter
        // takes a substring match.
        if let author = hints["author"], !author.isEmpty {
            queryItems.append(URLQueryItem(name: "author", value: author))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return [] }

        let response: OLSearchResponse = try await fetchWithRetry(url: url)
        return (response.docs ?? []).compactMap(Self.candidate(from:))
    }

    private static func candidate(from doc: OLDoc) -> CoverCandidate? {
        guard let coverID = doc.cover_i else { return nil }
        // L = large (≥800px wide), M = medium (~180px). Picker grid
        // tiles use M so the request fan-out is cheap; full-res download
        // on selection uses L.
        let fullURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")!
        let thumbURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-M.jpg")
        let subtitleParts: [String] = [
            doc.author_name?.first ?? "",
            doc.first_publish_year.map(String.init) ?? "",
        ].filter { !$0.isEmpty }
        let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
        // OL `key` is `/works/OL123W`; strip the prefix for a tidier id.
        let workKey = doc.key.split(separator: "/").last.map(String.init) ?? doc.key
        return CoverCandidate(
            id: "openlibrary:\(workKey):\(coverID)",
            title: doc.title,
            subtitle: subtitle,
            coverURL: fullURL,
            thumbnailURL: thumbURL,
            sourceLabel: "Open Library"
        )
    }
}

// MARK: - Retry helper

/// 3 attempts with backoff (200/400/800ms) on 429 / 503. Open Library
/// throttles unauthenticated callers at 100 req / 5 min / IP, and
/// returns 429 when exceeded; a short backoff typically clears it.
private func fetchWithRetry(url: URL) async throws -> OLSearchResponse {
    struct HTTPError: Error { let code: Int }
    var delayMs: UInt64 = 200
    var lastError: Error?
    for attempt in 0..<3 {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return try JSONDecoder().decode(OLSearchResponse.self, from: data)
                }
                if http.statusCode == 429 || http.statusCode == 503 {
                    lastError = HTTPError(code: http.statusCode)
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                        delayMs *= 2
                        continue
                    }
                }
                throw HTTPError(code: http.statusCode)
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

// MARK: - Response shape

private struct OLSearchResponse: Decodable {
    let docs: [OLDoc]?
}

private struct OLDoc: Decodable {
    let key: String
    let title: String
    let author_name: [String]?
    let cover_i: Int?
    let first_publish_year: Int?
    let isbn: [String]?
}
