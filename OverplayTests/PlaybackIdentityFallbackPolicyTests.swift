import Testing
@testable import Overplay

struct PlaybackIdentityFallbackPolicyTests {
    @Test("active queue fallback only applies to the same reported MusicKit item")
    func activeQueueFallbackRequiresMatchingReportedItem() {
        #expect(PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
            queueReportedTrackID: "music-current",
            activeQueueMusicItemID: "music-current"
        ))

        #expect(!PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
            queueReportedTrackID: "music-carplay-advanced",
            activeQueueMusicItemID: "music-stale"
        ))
    }

    @Test("a catalog-library flip for the same track is not an identity change")
    func aCatalogLibraryFlipForTheSameTrackIsNotAnIdentityChange() {
        #expect(!PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "i.abc123",
            oldLocalTrackID: nil,
            newMusicItemID: "1440833098",
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: ["i.abc123", "1440833098"]
        ))
    }

    @Test("a raw ID outside the known set is an identity change")
    func aRawIDOutsideTheKnownSetIsAnIdentityChange() {
        #expect(PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "i.abc123",
            oldLocalTrackID: nil,
            newMusicItemID: "999999",
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: ["i.abc123", "1440833098"]
        ))
        #expect(PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "i.abc123",
            oldLocalTrackID: nil,
            newMusicItemID: "1440833098",
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: []
        ))
    }

    @Test("local track IDs stay authoritative for identity changes")
    func localTrackIDsStayAuthoritativeForIdentityChanges() {
        #expect(PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "i.abc123",
            oldLocalTrackID: "local-1",
            newMusicItemID: "1440833098",
            newLocalTrackID: "local-2",
            currentTrackKnownMusicItemIDs: ["i.abc123", "1440833098"]
        ))
        #expect(!PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "i.abc123",
            oldLocalTrackID: "local-1",
            newMusicItemID: "999999",
            newLocalTrackID: "local-1",
            currentTrackKnownMusicItemIDs: []
        ))
    }

    @Test("identical raw IDs and missing sides never register a change")
    func identicalRawIDsAndMissingSidesNeverRegisterAChange() {
        #expect(!PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "music-1",
            oldLocalTrackID: nil,
            newMusicItemID: "music-1",
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: []
        ))
        #expect(!PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: nil,
            oldLocalTrackID: nil,
            newMusicItemID: "music-1",
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: []
        ))
        #expect(!PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: "music-1",
            oldLocalTrackID: "local-1",
            newMusicItemID: nil,
            newLocalTrackID: nil,
            currentTrackKnownMusicItemIDs: []
        ))
    }
}
