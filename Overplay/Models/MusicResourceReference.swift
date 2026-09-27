import Foundation

/// The response endpoint establishes the domain. Raw strings and metadata
/// never do. Library IDs belong to this dataset's configured Apple Music library.
nonisolated struct MusicResourceReference: Codable, Hashable, Sendable {
    enum Domain: String, Codable, Sendable { case catalogSong, librarySong }
    static let currentLibraryScope = "overplay-library-v2"
    var domain: Domain
    var scope: String
    var value: String

    static func catalog(_ value: String) -> Self {
        Self(domain: .catalogSong, scope: "apple-music", value: value)
    }

    static func library(_ value: String, scope: String = currentLibraryScope) -> Self {
        Self(domain: .librarySong, scope: scope, value: value)
    }
}
