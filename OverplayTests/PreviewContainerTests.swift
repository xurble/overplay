import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Preview container")
struct PreviewContainerTests {
    @Test("playlist management fixture seeds matching playlist rows")
    func playlistManagementFixtureSeedsMatchingPlaylistRows() throws {
        let fixture = PreviewContainer.makeFixture()
        let context = fixture.container.mainContext
        let playlistID = fixture.playlist.id
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
            .filter { $0.playlistID == playlistID }
            .sorted { $0.sortOrder < $1.sortOrder }
        let tracks = try context.fetch(FetchDescriptor<TrackRecord>())
        let trackIDs = Set(tracks.map(\.id))

        #expect(fixture.settings.selectedPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(items.map { $0.sortOrder } == [0, 1])
        #expect(items.allSatisfy { trackIDs.contains($0.trackID) })
        #expect(items.contains { !$0.isPlayable })
    }
}
