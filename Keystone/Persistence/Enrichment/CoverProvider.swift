import Foundation

/// One cover hit from a `CoverProvider.searchCovers`. Carries enough
/// metadata for the picker to render a discriminating row — title,
/// subtitle (year / author), the cover URL, and a source label so the
/// user sees which provider returned it.
struct CoverCandidate: Identifiable, Equatable, Sendable {
    /// Provider-stable id (`"openlibrary:OL123W"`, `"googlebooks:abc"`).
    /// Used as the SwiftUI list identity AND to dedupe across providers.
    let id: String
    /// Headline label — usually the book's title.
    let title: String
    /// Optional secondary line — author, year, edition info.
    let subtitle: String?
    /// Full-size cover URL the picker downloads on selection.
    let coverURL: URL
    /// Optional smaller URL for the grid thumbnail. Falls back to
    /// `coverURL` when nil.
    let thumbnailURL: URL?
    /// Display label for the provider chip on the thumbnail.
    let sourceLabel: String
}

/// A pluggable source of cover candidates for a given record. Parallel
/// to (and intentionally narrower than) `LookupProvider` — that one
/// drives full enrichment with every property; this one only fills the
/// record's cover, leaving title / author / description / tags alone.
///
/// Books currently fan out to two implementations (Google Books and
/// Open Library) so the user can pick from the union of their results.
/// Movies / TV use TMDB-only by virtue of having a single registered
/// provider.
protocol CoverProvider: Sendable {
    /// Database key this provider serves (e.g. "books").
    var databaseKey: String { get }
    /// Short label used in the picker's source chip.
    var sourceLabel: String { get }
    /// True iff the provider can run right now (e.g. has API keys).
    func isAvailable() async -> Bool
    /// Search for covers. Either returns the candidate list (possibly
    /// empty if the query matched nothing) or throws — the fan-out
    /// distinguishes between the two so the picker can surface a
    /// "Google Books temporarily unavailable" hint when a provider
    /// errors out vs simply returning zero results.
    func searchCovers(query: String, hints: [String: String]) async throws -> [CoverCandidate]
}

/// Per-source health record returned by the fan-out. The picker UI
/// uses this to distinguish "Google Books returned nothing" (probably
/// a query mismatch) from "Google Books errored" (rate limit / outage).
struct CoverSearchSourceStatus: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case ok
        case unavailable    // provider's `isAvailable` returned false
        case errored        // search threw — usually 429 / 503 after retries
    }
    let sourceLabel: String
    let outcome: Outcome
    let resultCount: Int
}

struct CoverSearchResult: Equatable, Sendable {
    let candidates: [CoverCandidate]
    let sources: [CoverSearchSourceStatus]
}

/// Where to look up the cover providers for a given database. Books has
/// two; everything else falls back to a single-provider list (or empty,
/// in which case the menu item is hidden upstream).
enum CoverProviderRegistry {
    static func providers(for databaseKey: String) -> [any CoverProvider] {
        switch databaseKey {
        case "books":
            return [GoogleBooksCoverProvider(), OpenLibraryCoverProvider()]
        case "movies":
            return [TMDBMovieCoverProvider()]
        case "tv_shows":
            return [TMDBTVCoverProvider()]
        default:
            return []
        }
    }

    /// Race every registered provider in parallel; merge results into
    /// a single de-duped list. Order is: provider order first, then
    /// the original within-provider ranking — so Google Books hits land
    /// before Open Library hits, with each provider's #1 result at the
    /// top of its section. Returns both the merged candidates and a
    /// per-source status array so the picker can surface error states.
    static func searchAll(
        databaseKey: String,
        query: String,
        hints: [String: String]
    ) async -> CoverSearchResult {
        let provs = providers(for: databaseKey)
        guard !provs.isEmpty else {
            return CoverSearchResult(candidates: [], sources: [])
        }
        return await withTaskGroup(
            of: (Int, [CoverCandidate], CoverSearchSourceStatus.Outcome).self
        ) { group in
            for (idx, p) in provs.enumerated() {
                group.addTask {
                    guard await p.isAvailable() else { return (idx, [], .unavailable) }
                    do {
                        let hits = try await p.searchCovers(query: query, hints: hints)
                        return (idx, hits, .ok)
                    } catch {
                        return (idx, [], .errored)
                    }
                }
            }
            var byProvider: [Int: (hits: [CoverCandidate], outcome: CoverSearchSourceStatus.Outcome)] = [:]
            for await (idx, hits, outcome) in group {
                byProvider[idx] = (hits, outcome)
            }
            var merged: [CoverCandidate] = []
            var seen = Set<String>()
            var sources: [CoverSearchSourceStatus] = []
            for idx in 0..<provs.count {
                let entry = byProvider[idx] ?? ([], .errored)
                for c in entry.hits {
                    if seen.insert(c.id).inserted { merged.append(c) }
                }
                sources.append(CoverSearchSourceStatus(
                    sourceLabel: provs[idx].sourceLabel,
                    outcome: entry.outcome,
                    resultCount: entry.hits.count
                ))
            }
            return CoverSearchResult(candidates: merged, sources: sources)
        }
    }
}
