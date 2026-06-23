import Foundation
import Testing
@testable import Overplay

@Suite("Playback identity store")
struct PlaybackIdentityStoreTests {
    @Test("stores aliases locally by player playlist and track")
    func storesAliasesLocallyByPlayerPlaylistAndTrack() throws {
        let suiteName = "OverplayTests.PlaybackIdentityStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackIdentityStore.recordAlias(
            "runtime-1",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: "local-1",
            to: defaults,
            flushImmediately: true
        )

        #expect(PlaybackIdentityStore.aliases(
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: "local-1",
            from: defaults
        ) == ["runtime-1"])
        #expect(PlaybackIdentityStore.aliases(
            playerID: "other",
            musicPlaylistID: "playlist-1",
            localTrackID: "local-1",
            from: defaults
        ).isEmpty)
    }

    @Test("alias lookup only resolves unambiguous candidate tracks")
    func aliasLookupOnlyResolvesUnambiguousCandidateTracks() throws {
        let suiteName = "OverplayTests.PlaybackIdentityStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackIdentityStore.recordAlias(
            "runtime-shared",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: "local-1",
            to: defaults
        )
        PlaybackIdentityStore.recordAlias(
            "runtime-shared",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: "local-2",
            to: defaults
        )

        #expect(PlaybackIdentityStore.localTrackID(
            matching: "runtime-shared",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            candidateLocalTrackIDs: ["local-1"],
            from: defaults
        ) == "local-1")
        #expect(PlaybackIdentityStore.localTrackID(
            matching: "runtime-shared",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            candidateLocalTrackIDs: ["local-1", "local-2"],
            from: defaults
        ) == nil)
    }

    @Test("rekeys and clears identity state locally")
    func rekeysAndClearsIdentityStateLocally() throws {
        let suiteName = "OverplayTests.PlaybackIdentityStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        PlaybackIdentityStore.recordAlias(
            "runtime-1",
            playerID: "main",
            musicPlaylistID: "p.old",
            localTrackID: "local-1",
            to: defaults
        )

        PlaybackIdentityStore.rekeyMusicPlaylistID(from: "p.old", to: "p.new", from: defaults, flushImmediately: true)

        #expect(PlaybackIdentityStore.aliases(
            playerID: "main",
            musicPlaylistID: "p.old",
            localTrackID: "local-1",
            from: defaults
        ).isEmpty)
        #expect(PlaybackIdentityStore.aliases(
            playerID: "main",
            musicPlaylistID: "p.new",
            localTrackID: "local-1",
            from: defaults
        ) == ["runtime-1"])

        PlaybackIdentityStore.clearAll(from: defaults, flushImmediately: true)

        #expect(PlaybackIdentityStore.aliases(
            playerID: "main",
            musicPlaylistID: "p.new",
            localTrackID: "local-1",
            from: defaults
        ).isEmpty)
    }
}
