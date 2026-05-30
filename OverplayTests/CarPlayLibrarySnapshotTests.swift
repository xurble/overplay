import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct CarPlayLibrarySnapshotTests {
    @Test func playlistSummariesIncludeActivePlayablePlaylistsInCarPlayOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)

        let oneTrue = PlaylistRecord(musicPlaylistID: "one", name: "Keepers", role: .oneTruePlaylist)
        let triage = PlaylistRecord(musicPlaylistID: "triage", name: "Inbox", role: .triage)
        let inactive = PlaylistRecord(musicPlaylistID: "inactive", name: "Old", role: .triage, isActive: false)
        context.insert(oneTrue)
        context.insert(triage)
        context.insert(inactive)

        let playableTrack = TrackRecord(title: "A", artistName: "Artist")
        let evictedTrack = TrackRecord(title: "B", artistName: "Artist")
        let inactiveTrack = TrackRecord(title: "C", artistName: "Artist")
        context.insert(playableTrack)
        context.insert(evictedTrack)
        context.insert(inactiveTrack)

        context.insert(PlaylistItemRecord(playlistID: oneTrue.id, trackID: playableTrack.id))
        context.insert(PlaylistItemRecord(playlistID: oneTrue.id, trackID: evictedTrack.id, evictedAt: .now))
        context.insert(PlaylistItemRecord(playlistID: inactive.id, trackID: inactiveTrack.id))
        try context.save()

        let summaries = try CarPlayLibrarySnapshot.playlistSummaries(in: context)

        #expect(summaries.map(\.title) == ["Keepers", "Inbox"])
        #expect(summaries.first?.isOneTruePlaylist == true)
        #expect(summaries.first?.playableTrackCount == 1)
        #expect(summaries.last?.playableTrackCount == 0)
    }
}
