import Foundation
import SwiftData

@Model
final class TrackRecord {
    var id: UUID = UUID()
    var catalogID: String?
    var libraryID: String?
    var title: String = ""
    var artistName: String = ""
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
    var musicKitPlaybackData: Data?
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
