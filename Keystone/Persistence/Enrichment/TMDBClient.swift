import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.TMDB")

/// Shared HTTP / decoding bits for `TMDBMovieProvider` and `TMDBTVProvider`.
///
/// Accepts either form of TMDB credential:
/// - **v4 read-access token** (a JWT — three base64 segments separated by
///   dots). Sent as `Authorization: Bearer <token>`.
/// - **v3 API key** (a 32-char hex string). Sent as the `api_key` query
///   parameter, no Authorization header.
///
/// The auth shape is detected from the key itself (see `isV4Token`), so
/// users don't need to know which one they pasted.
enum TMDBClient {
    static let baseURL = URL(string: "https://api.themoviedb.org/3")!
    /// `w1280` is sharp on Retina at any sensible rendering size
    /// (gallery hero, detail-view cover avatar, full-window display)
    /// without paying the ~2-3× disk cost of `original`. The CDN serves
    /// pre-resized variants, so this is a single fixed-size fetch — not
    /// a dynamic resize.
    static let posterBaseURL = URL(string: "https://image.tmdb.org/t/p/w1280")!

    /// Whether a key has been entered via Settings → API Keys.
    /// Movies and TV both gate on this.
    static func hasAPIKey() -> Bool {
        if let key = APIKeys.get(.tmdb)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return !key.isEmpty
        }
        return false
    }

    /// Fire a single GET with auth headers and JSON decoding. Returns nil
    /// (logged) on any failure — callers translate that into `.notFound`.
    static func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async -> T? {
        guard let key = APIKeys.get(.tmdb)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        guard let url = url(forPath: path, queryItems: queryItems, key: key) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.error("TMDB \(path, privacy: .public) status \(http.statusCode)")
                return nil
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("TMDB \(path, privacy: .public) \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Quick auth probe: hit `/configuration`, succeed only on HTTP 200.
    /// Used by the Settings → API Keys "Test" button.
    static func testKey() async -> Bool {
        guard let key = APIKeys.get(.tmdb)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return false }
        guard let url = url(forPath: "configuration", queryItems: [], key: key) else { return false }
        var request = URLRequest(url: url)
        applyAuth(to: &request, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// True when `key` looks like a v4 read-access token (a JWT — three
    /// non-empty segments separated by `.`). v3 API keys are flat 32-char
    /// hex strings with no dots.
    static func isV4Token(_ key: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    private static func url(forPath path: String, queryItems: [URLQueryItem], key: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        var items = queryItems
        if !isV4Token(key) {
            items.append(URLQueryItem(name: "api_key", value: key))
        }
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url
    }

    private static func applyAuth(to request: inout URLRequest, key: String) {
        if isV4Token(key) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - Movie + TV response shapes

struct TMDBMovieSearch: Decodable {
    let results: [TMDBMovieHit]
}

struct TMDBMovieHit: Decodable {
    let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview
        case releaseDate = "release_date"
        case posterPath = "poster_path"
    }
}

/// `/movie/{id}` returns more fields than the search hit — runtime and
/// imdb_id, in particular.
struct TMDBMovieDetail: Decodable {
    let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let runtime: Int?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime
        case releaseDate = "release_date"
        case posterPath = "poster_path"
    }
}

struct TMDBTVSearch: Decodable {
    let results: [TMDBTVHit]
}

struct TMDBTVHit: Decodable {
    let id: Int
    let name: String
    let overview: String?
    let firstAirDate: String?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
    }
}

struct TMDBTVDetail: Decodable {
    let id: Int
    let name: String
    let overview: String?
    let firstAirDate: String?
    let numberOfEpisodes: Int?
    let numberOfSeasons: Int?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case firstAirDate = "first_air_date"
        case numberOfEpisodes = "number_of_episodes"
        case numberOfSeasons = "number_of_seasons"
        case posterPath = "poster_path"
    }
}
