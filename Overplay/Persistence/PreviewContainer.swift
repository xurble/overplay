import Foundation
import SwiftData

enum PreviewContainer {
    @MainActor
    static func make() -> ModelContainer {
        let schema = Schema([
            OverplaySettings.self,
            TrackedTrack.self,
            PlaybackEvent.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self,
            SettingsRecord.self
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
            skipCount: 2,
            lastSeenInPlaylistAt: .now
        ))
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: evictedTrack.id,
            skipCount: 3,
            lastSeenInPlaylistAt: .now,
            evictedAt: .now,
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        ))
        try? context.save()
        return container
    }
}
