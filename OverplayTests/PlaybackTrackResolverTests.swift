import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback track resolver")
struct PlaybackTrackResolverTests {
    @Test("default playback playlist prefers selected active playlist then main playlist")
    func defaultPlaybackPlaylistPrefersSelectedThenMain() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let main = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let triage = PlaylistRecord(musicPlaylistID: "triage", name: "Triage", role: .triageBucket)
        let inactiveSelected = PlaylistRecord(
            musicPlaylistID: "inactive",
            name: "Inactive",
            role: .triageBucket,
            isActive: false
        )
        context.insert(main)
        context.insert(triage)
        context.insert(inactiveSelected)

        let selected = try PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: OverplaySettings(selectedPlaylistID: triage.musicPlaylistID),
            in: context
        )
        let fallback = try PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: OverplaySettings(selectedPlaylistID: inactiveSelected.musicPlaylistID),
            in: context
        )

        #expect(selected?.id == triage.id)
        #expect(fallback?.id == main.id)
    }

    @Test("default playback never selects a triage source")
    func defaultPlaybackNeverSelectsTriageSource() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let source = PlaylistRecord(
            musicPlaylistID: "source",
            name: "A Source",
            role: .triageSource
        )
        let bucket = PlaylistRecord(
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName,
            role: .triageBucket
        )
        context.insert(source)
        context.insert(bucket)

        let resolved = try PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: OverplaySettings(selectedPlaylistID: source.musicPlaylistID),
            in: context
        )

        #expect(resolved?.id == bucket.id)
    }
}
