import Foundation

enum SpotifyAPIError: LocalizedError {
    case notConfigured
    case notAuthorized
    case invalidResponse
    case httpStatus(Int, String?)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Spotify is not configured. Add a Spotify client ID to your build settings."
        case .notAuthorized:
            "Spotify is not connected. Sign in from Linked Playlists."
        case .invalidResponse:
            "Spotify returned an invalid response."
        case let .httpStatus(code, message):
            if let message, !message.isEmpty {
                "Spotify request failed (\(code)): \(message)"
            } else {
                "Spotify request failed (\(code))."
            }
        case .decodingFailed:
            "Spotify returned data that could not be decoded."
        }
    }
}

struct SpotifyUserProfile: Decodable, Sendable {
    var id: String
    var display_name: String?
}

struct SpotifyPlaylistPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var id: String
        var name: String
        var tracks: TrackCount?

        struct TrackCount: Decodable, Sendable {
            var total: Int
        }
    }

    var items: [Item]
    var next: String?
}

struct SpotifyPlaylistTracksPage: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var track: SpotifyTrack?
    }

    var items: [Item]
    var next: String?
}

struct SpotifyTrack: Decodable, Sendable, Hashable {
    struct Artist: Decodable, Sendable, Hashable {
        var name: String
    }

    struct Album: Decodable, Sendable, Hashable {
        var name: String
        var images: [Image]?

        struct Image: Decodable, Sendable, Hashable {
            var url: String
        }
    }

    struct ExternalIDs: Decodable, Sendable, Hashable {
        var isrc: String?
    }

    var id: String?
    var name: String
    var artists: [Artist]
    var album: Album
    var duration_ms: Int?
    var external_ids: ExternalIDs?

    var artistName: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artworkURL: String? {
        album.images?.first?.url
    }

    var isrc: String? {
        external_ids?.isrc
    }
}

struct SpotifyTokenResponse: Decodable, Sendable {
    var access_token: String
    var token_type: String
    var expires_in: Int
    var refresh_token: String?
    var scope: String?
}

actor SpotifyAPIClient {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> SpotifyTokenResponse {
        guard SpotifyConfiguration.isConfigured else {
            throw SpotifyAPIError.notConfigured
        }

        var request = URLRequest(url: SpotifyConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfiguration.redirectURI,
            "client_id": SpotifyConfiguration.clientID,
            "code_verifier": verifier
        ]
        request.httpBody = formEncoded(body)

        return try await decode(SpotifyTokenResponse.self, from: request)
    }

    func refreshAccessToken(_ refreshToken: String) async throws -> SpotifyTokenResponse {
        guard SpotifyConfiguration.isConfigured else {
            throw SpotifyAPIError.notConfigured
        }

        var request = URLRequest(url: SpotifyConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": SpotifyConfiguration.clientID
        ]
        request.httpBody = formEncoded(body)

        return try await decode(SpotifyTokenResponse.self, from: request)
    }

    func fetchCurrentUser(accessToken: String) async throws -> SpotifyUserProfile {
        try await get("me", accessToken: accessToken)
    }

    func fetchPlaylists(accessToken: String) async throws -> [SpotifyPlaylist] {
        var playlists: [SpotifyPlaylist] = []
        var nextURL: URL? = SpotifyConfiguration.apiBaseURL.appending(path: "me/playlists").appending(queryItems: [
            URLQueryItem(name: "limit", value: "50")
        ])

        while let url = nextURL {
            let page: SpotifyPlaylistPage = try await get(url, accessToken: accessToken)
            playlists.append(contentsOf: page.items.map {
                SpotifyPlaylist(
                    id: $0.id,
                    name: $0.name,
                    trackCount: $0.tracks?.total,
                    ownerName: nil
                )
            })
            nextURL = page.next.flatMap(URL.init(string:))
        }

        return playlists
    }

    func fetchPlaylistTracks(playlistID: String, accessToken: String) async throws -> [SpotifyTrack] {
        var tracks: [SpotifyTrack] = []
        var nextURL: URL? = SpotifyConfiguration.apiBaseURL
            .appending(path: "playlists/\(playlistID)/tracks")
            .appending(queryItems: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "additional_types", value: "track")
            ])

        while let url = nextURL {
            let page: SpotifyPlaylistTracksPage = try await get(url, accessToken: accessToken)
            tracks.append(contentsOf: page.items.compactMap(\.track).filter { $0.id != nil })
            nextURL = page.next.flatMap(URL.init(string:))
        }

        return tracks
    }

    private func get<T: Decodable>(_ path: String, accessToken: String) async throws -> T {
        let url = SpotifyConfiguration.apiBaseURL.appending(path: path)
        return try await get(url, accessToken: accessToken)
    }

    private func get<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await decode(T.self, from: request)
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw SpotifyAPIError.httpStatus(httpResponse.statusCode, message)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SpotifyAPIError.decodingFailed
        }
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        values
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
