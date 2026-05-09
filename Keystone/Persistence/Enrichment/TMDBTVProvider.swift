import Foundation

/// Fills in `tmdb_id`, `first_air_date`, `season_count`, `episode_count`,
/// `overview`, and the poster for TV-show records. Requires a TMDB
/// credential — either the v3 API key or the v4 read-access token works
/// (Settings → API Keys → TMDB).
struct TMDBTVProvider: EnrichmentProvider, LookupProvider {
    let databaseKey = "tv_shows"
    let triggerPropertyKey = "tmdb_id"

    func isAvailable() async -> Bool { TMDBClient.hasAPIKey() }

    func searchCandidates(query: String) async -> [LookupCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let search: TMDBTVSearch = await TMDBClient.get(
            "search/tv",
            queryItems: [URLQueryItem(name: "query", value: trimmed)]
        ) else { return [] }
        return search.results.prefix(10).map { hit in
            let apply = Self.apply(from: hit, detail: nil)
            let year: String? = hit.firstAirDate.flatMap { $0.isEmpty ? nil : String($0.prefix(4)) }
            return LookupCandidate(
                id: String(hit.id),
                title: hit.name,
                subtitle: year,
                coverURL: apply.coverImageURL,
                apply: apply
            )
        }
    }

    func enrich(record: EnrichmentRecord) async -> EnrichmentResult {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .notFound }
        let year = record.propertyValues["year"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        var queryItems = [URLQueryItem(name: "query", value: title)]
        if let year, !year.isEmpty {
            queryItems.append(URLQueryItem(name: "first_air_date_year", value: year))
        }

        guard let search: TMDBTVSearch = await TMDBClient.get("search/tv", queryItems: queryItems) else {
            return .unavailable(reason: "TMDB request failed")
        }

        let hits = search.results
        guard let top = hits.first else { return .notFound }

        let confident = Self.titlesMatch(input: title, candidate: top.name)
        if confident {
            let detail: TMDBTVDetail? = await TMDBClient.get("tv/\(top.id)", queryItems: [])
            return .resolved(Self.apply(from: top, detail: detail))
        }
        let candidates = hits.prefix(5).map { Self.apply(from: $0, detail: nil) }
        return candidates.isEmpty ? .notFound : .ambiguous(Array(candidates))
    }

    private static func titlesMatch(input: String, candidate: String) -> Bool {
        let a = input.lowercased(); let b = candidate.lowercased()
        return a == b || b.hasPrefix(a)
    }

    private static func apply(from hit: TMDBTVHit, detail: TMDBTVDetail?) -> EnrichmentApply {
        var updates: [String: String] = ["tmdb_id": String(hit.id)]
        if let date = hit.firstAirDate ?? detail?.firstAirDate, !date.isEmpty {
            updates["first_air_date"] = date
        }
        if let overview = hit.overview ?? detail?.overview, !overview.isEmpty {
            updates["overview"] = overview
        }
        if let seasons = detail?.numberOfSeasons, seasons > 0 {
            updates["season_count"] = String(seasons)
        }
        if let episodes = detail?.numberOfEpisodes, episodes > 0 {
            updates["episode_count"] = String(episodes)
        }
        let posterURL: URL? = (detail?.posterPath ?? hit.posterPath).flatMap { path in
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return TMDBClient.posterBaseURL.appendingPathComponent(trimmed)
        }
        let preview = hit.firstAirDate.map { "\(hit.name) (\($0.prefix(4)))" } ?? hit.name
        return EnrichmentApply(
            propertyUpdates: updates,
            coverImageURL: posterURL,
            previewLabel: preview
        )
    }
}
