import Foundation
import Testing
@testable import Overplay

@Suite("Playlist remote change policy")
struct PlaylistRemoteChangePolicyTests {
    private static let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("an unchanged modification date skips the track fetch")
    func anUnchangedModificationDateSkipsTheTrackFetch() {
        #expect(
            PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: Self.modifiedAt,
                storedLastModifiedAt: Self.modifiedAt,
                hasSyncedSuccessfully: true
            )
        )
    }

    @Test("a newer modification date fetches")
    func aNewerModificationDateFetches() {
        #expect(
            !PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: Self.modifiedAt.addingTimeInterval(60),
                storedLastModifiedAt: Self.modifiedAt,
                hasSyncedSuccessfully: true
            )
        )
    }

    @Test("a missing remote modification date always fetches")
    func aMissingRemoteModificationDateAlwaysFetches() {
        // Apple Music does not report one for every library playlist.
        #expect(
            !PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: nil,
                storedLastModifiedAt: Self.modifiedAt,
                hasSyncedSuccessfully: true
            )
        )
    }

    @Test("a missing stored fingerprint always fetches")
    func aMissingStoredFingerprintAlwaysFetches() {
        #expect(
            !PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: Self.modifiedAt,
                storedLastModifiedAt: nil,
                hasSyncedSuccessfully: true
            )
        )
    }

    @Test("no successful previous sync always fetches")
    func noSuccessfulPreviousSyncAlwaysFetches() {
        // Matching timestamps mean nothing when there is no trustworthy
        // local track data to keep.
        #expect(
            !PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: Self.modifiedAt,
                storedLastModifiedAt: Self.modifiedAt,
                hasSyncedSuccessfully: false
            )
        )
    }

    @Test("both dates missing always fetches")
    func bothDatesMissingAlwaysFetches() {
        #expect(
            !PlaylistRemoteChangePolicy.isUnchanged(
                remoteLastModifiedAt: nil,
                storedLastModifiedAt: nil,
                hasSyncedSuccessfully: true
            )
        )
    }
}
