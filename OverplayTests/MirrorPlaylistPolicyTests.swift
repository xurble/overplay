import Foundation
import Testing
@testable import Overplay

@Suite("Mirror playlist rules")
struct MirrorPlaylistPolicyTests {
    private func state(
        musicPlaylistID: String = "mirror-1",
        sourcePlaylistID: String = "source-1",
        scope: String = "active",
        writtenMusicItemIDs: [String] = ["a", "b"]
    ) -> MirrorPlaylistState {
        MirrorPlaylistState(
            musicPlaylistID: musicPlaylistID,
            sourcePlaylistID: sourcePlaylistID,
            scope: scope,
            writtenMusicItemIDs: writtenMusicItemIDs
        )
    }

    @Test("an unwritten mirror always needs a rewrite")
    func unwrittenMirrorNeedsRewrite() {
        #expect(MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["a"],
            sourcePlaylistID: "source-1",
            scope: "active",
            state: nil
        ))
    }

    @Test("an unchanged mirror is reused without a library write")
    func unchangedMirrorIsReused() {
        #expect(!MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["a", "b"],
            sourcePlaylistID: "source-1",
            scope: "active",
            state: state()
        ))
    }

    @Test("a retirement, addition, or reorder forces a rewrite")
    func contentDriftForcesRewrite() {
        #expect(MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["a"],
            sourcePlaylistID: "source-1",
            scope: "active",
            state: state()
        ))
        #expect(MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["b", "a"],
            sourcePlaylistID: "source-1",
            scope: "active",
            state: state()
        ))
    }

    @Test("switching playlist or scope forces a rewrite")
    func switchingPlaylistOrScopeForcesRewrite() {
        #expect(MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["a", "b"],
            sourcePlaylistID: "source-2",
            scope: "active",
            state: state()
        ))
        #expect(MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: ["a", "b"],
            sourcePlaylistID: "source-1",
            scope: "retired",
            state: state()
        ))
    }

    @Test("the rewriting edit is never aimed at a playlist the user linked")
    func rewriteNeverTargetsALinkedPlaylist() {
        #expect(!MirrorPlaylistPolicy.isSafeMirrorTarget(
            mirrorPlaylistID: "source-1",
            linkedPlaylistIDs: ["source-1", "source-2"]
        ))
        #expect(MirrorPlaylistPolicy.isSafeMirrorTarget(
            mirrorPlaylistID: "mirror-1",
            linkedPlaylistIDs: ["source-1", "source-2"]
        ))
        #expect(!MirrorPlaylistPolicy.isSafeMirrorTarget(
            mirrorPlaylistID: "",
            linkedPlaylistIDs: [String]()
        ))
    }

    @Test("mirror state round-trips through its store")
    func mirrorStateRoundTripsThroughItsStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "mirror-playlist-policy-tests"))
        defaults.removePersistentDomain(forName: "mirror-playlist-policy-tests")
        defer { defaults.removePersistentDomain(forName: "mirror-playlist-policy-tests") }

        #expect(MirrorPlaylistStore.load(from: defaults) == nil)
        MirrorPlaylistStore.save(state(), to: defaults)

        let loaded = try #require(MirrorPlaylistStore.load(from: defaults))
        #expect(loaded.musicPlaylistID == "mirror-1")
        #expect(loaded.writtenMusicItemIDs == ["a", "b"])

        MirrorPlaylistStore.clear(from: defaults)
        #expect(MirrorPlaylistStore.load(from: defaults) == nil)
    }
}
