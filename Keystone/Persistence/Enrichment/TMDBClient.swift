import Foundation
import OSLog

private let log = Logger(subsystem: "Keystone", category: "Enrichment.TMDB")

/// Shared HTTP / decoding bits for `TMDBMovieProvider` and `TMDBTVProvider`.
/// Auth uses the v4 read-access token (Bearer).
enum TMDBClient {
    static let baseURL = URL(string: "https://api.themoviedb.org/3")!
    /// w780 is the pre-canned width that Apple-Photos-class displays read
    /// well at; smaller widths look soft on Retina, larger ones bloat
    /// asset storage.
    static let posterBaseURL = URL(string: "https://image.tmdb.org/t/p/w780")!

    /// Whether a Bearer token has been entered via Settings → API Keys.
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
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
        let url = baseURL.appendingPathComponent("configuration")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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
