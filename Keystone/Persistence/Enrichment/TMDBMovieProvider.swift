import Foundation

/// Fills in `tmdb_id`, `release_date`, `runtime_minutes`, `overview`, and
/// the poster image for movie records. Requires a TMDB v4 read-access
/// token (Settings → API Keys → TMDB).
struct TMDBMovieProvider: EnrichmentProvider {
    let databaseKey = "movies"
    let triggerPropertyKey = "tmdb_id"

    func isAvailable() async -> Bool { TMDBClient.hasAPIKey() }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .notFound }
        let year = record.propertyValues["year"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var queryItems = [URLQueryItem(name: "query", value: title)]
        if let year, !year.isEmpty {
            queryItems.append(URLQueryItem(name: "year", value: year))
        }

        guard let search: TMDBMovieSearch = await TMDBClient.get("search/movie", queryItems: queryItems) else {
            return .unavailable(reason: "TMDB request failed")
        }

        let hits = search.results
        guard let top = hits.first else { return .notFound }

        let confident = Self.titlesMatch(input: title, candidate: top.title)
        if confident {
            // Fetch detail for runtime — search hit doesn't include it.
            let detail: TMDBMovieDetail? = await TMDBClient.get("movie/\(top.id)", queryItems: [])
            return .resolved(Self.apply(from: top, detail: detail))
        }
        let candidates = hits.prefix(5).map { Self.apply(from: $0, detail: nil) }
        return candidates.isEmpty ? .notFound : .ambiguous(Array(candidates))
    }

    private static func titlesMatch(input: String, candidate: String) -> Bool {
        let a = input.lowercased(); let b = candidate.lowercased()
        return a == b || b.hasPrefix(a)
    }

    private static func apply(from hit: TMDBMovieHit, detail: TMDBMovieDetail?) -> EnrichmentApply {
        var updates: [String: String] = ["tmdb_id": String(hit.id)]
        if let date = hit.releaseDate ?? detail?.releaseDate, !date.isEmpty {
            updates["release_date"] = date
        }
        if let overview = hit.overview ?? detail?.overview, !overview.isEmpty {
            updates["overview"] = overview
        }
        if let runtime = detail?.runtime, runtime > 0 {
            updates["runtime_minutes"] = String(runtime)
        }
        let posterURL: URL? = (detail?.posterPath ?? hit.posterPath).flatMap { path in
            // path comes prefixed with `/`. URLComponents balks at a path
            // appended that starts with `/`; trim it.
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return TMDBClient.posterBaseURL.appendingPathComponent(trimmed)
        }
        let preview = hit.releaseDate.map { "\(hit.title) (\($0.prefix(4)))" } ?? hit.title
        return EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: posterURL,
            previewLabel: preview
        )
    }
}
