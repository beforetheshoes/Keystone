import Foundation

/// A pluggable lookup that fills in missing fields on records of a specific
/// database. The original concrete behavior lives in `MapKitVendorProvider`;
/// `GoogleBooksProvider`, `TMDBMovieProvider`, and `TMDBTVProvider` extend the
/// pattern to other databases. Providers run sequentially under
/// `EnrichmentService` so they don't have to manage concurrency or rate
/// limiting in their own code.
protocol EnrichmentProvider: Sendable {
    /// Database key this provider enriches (e.g. "vendors", "books").
    var databaseKey: String { get }

    /// Property whose absence/emptiness marks a record as "needs enrichment".
    /// vendors → "place_id"; books → "isbn"; movies/tv_shows → "tmdb_id".
    /// Records with a non-empty value for this property are skipped.
    var triggerPropertyKey: String { get }

    /// Fast check: does this provider have what it needs to run right now?
    /// Returns false when an API key is missing so the loop skips it cleanly
    /// without an SQL query or a network call.
    func isAvailable() async -> Bool

    /// Look up enrichment for a record. The service serializes calls and
    /// applies blanks-only writes from `.resolved`, so providers don't have
    /// to coordinate concurrency themselves.
    func enrich(record: EnrichmentRecord) async -> EnrichmentResult
}

/// Snapshot of a record at the time of an enrichment call.
struct EnrichmentRecord: Sendable, Equatable {
    let id: String
    let databaseID: String
    let title: String
    /// Property key → string value. Provider reads what it needs (e.g.
    /// `GoogleBooksProvider` reads "author"). Missing keys are absent from
    /// the dictionary; keys with explicitly empty values are absent too.
    let propertyValues: [String: String]
}

/// Outcome of one provider lookup.
enum EnrichmentResult: Sendable {
    /// Confident match — `EnrichmentService` writes the apply payload.
    case resolved(EnrichmentApply)
    /// Multiple plausible candidates without a clear winner. Logged and
    /// skipped by the auto-apply loop; some databases (vendors) surface a
    /// candidate-picker sheet from interactive UI separately.
    case ambiguous([EnrichmentApply])
    /// No candidates at all (e.g., a private vendor not in MapKit).
    case notFound
    /// Provider can't run right now — typically a missing API key. Caller
    /// logs the reason and moves on.
    case unavailable(reason: String)
}

/// What a provider wants applied to a record. `EnrichmentService` writes
/// only blank fields by default; CLI `--overwrite` flips that.
struct EnrichmentApply: Sendable, Equatable {
    /// Property updates, keyed by property key. Values that are non-empty
    /// strings get written; empty/nil values are no-ops.
    let propertyUpdates: [String: String]

    /// Optional cover image URL. When set, `EnrichmentService` downloads
    /// the file via `CoverImageImporter`, attaches it as an asset, and
    /// sets `record.cover_asset_id`. Best-effort: a failed download leaves
    /// the property updates intact.
    let coverImageURL: URL?

    /// Optional preview blurb shown by interactive candidate-picker UIs
    /// (e.g. the existing vendor lookup sheet). Free-form text — provider
    /// chooses the format.
    let previewLabel: String?

    init(
        propertyUpdates: [String: String],
        coverImageURL: URL? = nil,
        previewLabel: String? = nil
    ) {
        self.propertyUpdates = propertyUpdates
        self.coverImageURL = coverImageURL
        self.previewLabel = previewLabel
    }
}

// MARK: - Interactive lookup (lookup-first creation)

/// A single candidate returned by `LookupProvider.searchCandidates`.
/// Drives the candidate-picker UI shown when the user clicks **+ New**
/// on a database that has interactive lookup wired up.
///
/// `apply` carries the same `EnrichmentApply` payload the post-create
/// `EnrichmentProvider.enrich(record:)` path produces, so picking a
/// candidate doesn't require a second round-trip — the create flow
/// dispatches `createRecord(title:)` then writes `apply` directly.
struct LookupCandidate: Identifiable, Equatable, Sendable {
    /// Provider-stable id (e.g. TMDB's numeric id, Google Books' volume
    /// id, MapKit's place id). Used as the SwiftUI list identity.
    let id: String
    /// Headline label for the row (e.g. movie title, book title).
    let title: String
    /// Optional secondary line — author, year, address.
    let subtitle: String?
    /// Optional thumbnail URL. The picker renders via `AsyncImage`.
    let coverURL: URL?
    /// Payload to write after the record is created. Includes the
    /// trigger property so the new record won't be re-picked by the
    /// background enrichment pass.
    let apply: EnrichmentApply
}

/// A provider that supports interactive search. Implementing this is
/// optional — databases without an implementation fall back to the plain
/// "create blank" flow.
protocol LookupProvider: Sendable {
    /// Database key this provider serves (e.g. "books", "movies",
    /// "tv_shows", "vendors", "restaurants").
    var databaseKey: String { get }

    /// True when the provider has what it needs (e.g. an API key) to
    /// answer a search. The picker hides itself when no provider is
    /// available for the current database.
    func isAvailable() async -> Bool

    /// Up to ~10 candidates for `query`. Returns an empty list rather
    /// than throwing on transient errors so the picker just shows
    /// "no matches" instead of an error toast.
    func searchCandidates(query: String) async -> [LookupCandidate]
}

/// Static lookup of which provider serves a given database. Kept tiny
/// and synchronous so view code can ask "is lookup wired up here?" in
/// `body` without hopping actors.
enum LookupRegistry {
    static func provider(for databaseKey: String) -> (any LookupProvider)? {
        switch databaseKey {
        case "books":
            return GoogleBooksProvider()
        case "movies":
            return TMDBMovieProvider()
        case "tv_shows":
            return TMDBTVProvider()
        #if canImport(MapKit)
        case "vendors":
            if #available(iOS 26.0, macOS 26.0, *) {
                return MapKitVendorProvider()
            }
            return nil
        // Restaurants are intentionally absent here — their schema
        // delegates address/phone/etc to a linked vendor record, so a
        // restaurant lookup-first flow would need to create both rows
        // and wire the relation. Out of scope for the first cut.
        #endif
        default:
            return nil
        }
    }

    /// True when `databaseKey` has a provider AND that provider is
    /// available right now (e.g. TMDB key set). Used by the **+ New**
    /// button to decide between lookup-first and blank-create.
    static func hasAvailableProvider(for databaseKey: String) async -> Bool {
        guard let provider = provider(for: databaseKey) else { return false }
        return await provider.isAvailable()
    }
}
