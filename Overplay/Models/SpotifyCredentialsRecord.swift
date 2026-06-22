import Foundation
import SwiftData

@Model
final class SpotifyCredentialsRecord {
    var id: UUID = UUID()
    var accessToken: String = ""
    var refreshToken: String = ""
    var expiresAt: Date = .distantPast
    var scope: String = ""
    var spotifyUserID: String = ""
    var displayName: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var hasAccessToken: Bool {
        !accessToken.isEmpty
    }

    var canRefresh: Bool {
        !refreshToken.isEmpty
    }

    var isAccessTokenValid: Bool {
        hasAccessToken && expiresAt > .now
    }

    init(
        id: UUID = UUID(),
        accessToken: String = "",
        refreshToken: String = "",
        expiresAt: Date = .distantPast,
        scope: String = "",
        spotifyUserID: String = "",
        displayName: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.spotifyUserID = spotifyUserID
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
