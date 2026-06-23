import Foundation

enum SpotifyConfiguration {
    static let redirectURI = "overplay://spotify-callback"
    static let authorizationURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let apiBaseURL = URL(string: "https://api.spotify.com/v1")!

    static var clientID: String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
              !clientID.isEmpty,
              clientID != "$(SPOTIFY_CLIENT_ID)" else {
            return ""
        }
        return clientID
    }

    static var isConfigured: Bool {
        !clientID.isEmpty
    }
}
