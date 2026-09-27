import Foundation
import SwiftData

@Model
final class LibraryTrackV2 {
    var id: UUID = UUID()
    var catalogID: String?
    var libraryID: String?
    var isrc: String?
    /// Confirmed aliases survive merging and prevent sync from recreating donors.
    var confirmedAliases: [MusicResourceReference] = []
    var libraryScope: String = MusicResourceReference.currentLibraryScope
    var identityAliases: [String] { confirmedAliases.map(\.value) }
    var identityReferences: Set<MusicResourceReference> {
        Set(confirmedAliases + [
            catalogID.map { MusicResourceReference.catalog($0) },
            libraryID.map { MusicResourceReference.library($0, scope: libraryScope) }
        ].compactMap { $0 })
    }
    /// Alternatives are evidence for review, never automatic merge keys.
    var equivalentCatalogIDs: [String] = []
    var hasDocumentedIdentity: Bool = false
    var title: String = ""
    var artistName: String = ""
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
    var musicKitPlaybackData: Data? {
        get { DevicePlaybackCache.shared.data(for: id) }
        set { DevicePlaybackCache.shared.set(newValue, for: id) }
    }
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        libraryID: String? = nil,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURLTemplate: String? = nil,
        durationSeconds: Double? = nil,
        musicKitPlaybackData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID
        self.libraryID = libraryID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURLTemplate = artworkURLTemplate
        self.durationSeconds = durationSeconds
        self.musicKitPlaybackData = musicKitPlaybackData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// Source-level name shared by all playback surfaces; storage identity is V2.
typealias TrackRecord = LibraryTrackV2
