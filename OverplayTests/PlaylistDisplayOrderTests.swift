import Foundation
import Testing
@testable import Overplay

@Suite("Playlist display order")
struct PlaylistDisplayOrderTests {
    @Test func newestAddsAndMovesComeFirstRegardlessOfCounts() {
        let old = PlaylistItemRecord(playlistID: UUID(), trackID: UUID(), playthroughCount: 900,
                                     createdAt: Date(timeIntervalSince1970: 1))
        let recent = PlaylistItemRecord(playlistID: old.playlistID, trackID: UUID(),
                                        createdAt: Date(timeIntervalSince1970: 2))
        #expect(PlaylistDisplayOrder.orderedItems([old, recent]).map(\.id) == [recent.id, old.id])
        old.locationChangedAt = Date(timeIntervalSince1970: 3)
        #expect(PlaylistDisplayOrder.orderedItems([old, recent]).map(\.id) == [old.id, recent.id])
    }

    @Test func retiredUsesRetirementDateWithStableTies() {
        let first = PlaylistItemRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            playlistID: UUID(), trackID: UUID(), evictedAt: Date(timeIntervalSince1970: 10),
            createdAt: Date(timeIntervalSince1970: 50))
        let second = PlaylistItemRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            playlistID: first.playlistID, trackID: UUID(), evictedAt: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 1))
        #expect(PlaylistDisplayOrder.orderedItems([first, second], scope: .retired).map(\.id) == [second.id, first.id])
        first.evictedAt = second.evictedAt
        #expect(PlaylistDisplayOrder.orderedItems([second, first], scope: .retired).map(\.id) == [first.id, second.id])
    }
}
