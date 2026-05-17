import Foundation

/// TMDB movie poster picker. Adapts `TMDBMovieProvider.searchCandidates`
/// into cover-only candidates.
struct TMDBMovieCoverProvider: CoverProvider {
    let databaseKey = "movies"
    let sourceLabel = "TMDB"

    func isAvailable() async -> Bool {
        await TMDBMovieProvider().isAvailable()
    }

    func searchCovers(query: String, hints: [String: String]) async throws -> [CoverCandidate] {
        let candidates = await TMDBMovieProvider().searchCandidates(query: query)
        return candidates.compactMap { lookup in
            guard let cover = lookup.coverURL else { return nil }
            return CoverCandidate(
                id: "tmdb:\(lookup.id)",
                title: lookup.title,
                subtitle: lookup.subtitle,
                coverURL: cover,
                thumbnailURL: cover,
                sourceLabel: "TMDB"
            )
        }
    }
}

/// TMDB TV poster picker. Mirror of the movie variant against the
/// TV-search endpoint.
struct TMDBTVCoverProvider: CoverProvider {
    let databaseKey = "tv_shows"
    let sourceLabel = "TMDB"

    func isAvailable() async -> Bool {
        await TMDBTVProvider().isAvailable()
    }

    func searchCovers(query: String, hints: [String: String]) async throws -> [CoverCandidate] {
        let candidates = await TMDBTVProvider().searchCandidates(query: query)
        return candidates.compactMap { lookup in
            guard let cover = lookup.coverURL else { return nil }
            return CoverCandidate(
                id: "tmdb:\(lookup.id)",
                title: lookup.title,
                subtitle: lookup.subtitle,
                coverURL: cover,
                thumbnailURL: cover,
                sourceLabel: "TMDB"
            )
        }
    }
}
