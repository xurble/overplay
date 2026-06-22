import Foundation
import SwiftData

enum PreviewContainer {
    struct Fixture {
        var container: ModelContainer
        var settings: OverplaySettings
        var playlist: PlaylistRecord
    }

    @MainActor
    static func make() -> ModelContainer {
        makeFixture().container
    }

    @MainActor
    static func makeFixture() -> Fixture {
        let schema = Schema([
            OverplaySettings.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self,
            SpotifyCredentialsRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let settings = OverplaySettings(
            selectedPlaylistID: "preview-playlist",
            selectedPlaylistName: "Overplay"
        )
        let playlist = PlaylistRecord(
            musicPlaylistID: "preview-playlist",
            name: "Overplay",
            role: .oneTruePlaylist
        )
        let playableTrack = TrackRecord(
            catalogID: "preview-track",
            libraryID: "preview-track",
            title: "Glasshouse",
            artistName: "The Sample Set",
            albumTitle: "Overplay Sessions",
            durationSeconds: 214
        )
        let evictedTrack = TrackRecord(
            catalogID: "preview-evicted",
            libraryID: "preview-evicted",
            title: "Too Soon",
            artistName: "The Sample Set",
            durationSeconds: 186
        )
        context.insert(settings)
        context.insert(playlist)
        context.insert(playableTrack)
        context.insert(evictedTrack)
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: playableTrack.id,
            sortOrder: 0,
            skipCount: 2,
            lastSeenInPlaylistAt: .now
        ))
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: evictedTrack.id,
            sortOrder: 1,
            skipCount: 3,
            lastSeenInPlaylistAt: .now,
            evictedAt: .now,
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        ))
        try? context.save()
        return Fixture(container: container, settings: settings, playlist: playlist)
    }
}
