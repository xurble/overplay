import Foundation
import Testing
@testable import Overplay

@Suite("Validated playback ID associations")
struct PlaybackAssociationStoreTests {
    @Test("batch learning preserves sequential conflict handling and avoids duplicate records")
    func batchLearning() throws {
        let suite = "association-batch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = PlaybackTrackMatchMetadata(title: "Song", artist: "Artist")
        let first = PlaybackAssociationStore.Association(scope: "scope", playerID: "player", playlistID: "list",
            localTrackID: "first", musicItemID: "returned", localMetadata: metadata, reportedMetadata: metadata, learnedAt: .now)
        var conflicting = first
        conflicting.localTrackID = "other"
        PlaybackAssociationStore.record([first, first], defaults: defaults)
        let firstData = try #require(defaults.data(forKey: PlaybackAssociationStore.key))
        #expect(try JSONDecoder().decode([PlaybackAssociationStore.Association].self, from: firstData).count == 1)
        PlaybackAssociationStore.record([first, conflicting], defaults: defaults)
        let conflictData = try #require(defaults.data(forKey: PlaybackAssociationStore.key))
        #expect(try JSONDecoder().decode([PlaybackAssociationStore.Association].self, from: conflictData).isEmpty)
    }

    @Test("association survives reload but is isolated by account, storefront, player and playlist")
    func persistAndScope() throws {
        let suite = "associations-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = PlaybackTrackMatchMetadata(title: "Punk Guy", artist: "NOFX", duration: 60)
        var member = PendingQueueCorrelation(playlistItemID: UUID(), localTrackID: "local", queuedMusicItemID: "known")
        member.metadata = metadata
        let scope = PlaybackAssociationStore.scopeKey(account: "one", storefront: "gb")
        let record = PlaybackAssociationStore.Association(scope: scope, playerID: "main", playlistID: "playlist", localTrackID: "local", musicItemID: "apple-returned", localMetadata: metadata, reportedMetadata: metadata, learnedAt: .now)
        PlaybackAssociationStore.record(record, defaults: defaults)
        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(PlaybackAssociationStore.validated(scope: scope, playerID: "main", playlistID: "playlist", members: [member], defaults: reloaded) == [record])
        for wrongScope in [PlaybackAssociationStore.scopeKey(account: "two", storefront: "gb"), PlaybackAssociationStore.scopeKey(account: "one", storefront: "us")] {
            #expect(PlaybackAssociationStore.validated(scope: wrongScope, playerID: "main", playlistID: "playlist", members: [member], defaults: reloaded).isEmpty)
        }
        #expect(PlaybackAssociationStore.validated(scope: scope, playerID: "other", playlistID: "playlist", members: [member], defaults: reloaded).isEmpty)
        #expect(PlaybackAssociationStore.validated(scope: scope, playerID: "main", playlistID: "other", members: [member], defaults: reloaded).isEmpty)
    }

    @Test("deleted, changed, expired and conflicting tracks invalidate cached IDs", arguments: ["deleted", "changed", "expired", "conflict"])
    func invalidate(reason: String) throws {
        let suite = "associations-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = PlaybackTrackMatchMetadata(title: "Punk Guy", artist: "NOFX")
        var member = PendingQueueCorrelation(playlistItemID: UUID(), localTrackID: "local", queuedMusicItemID: "known")
        member.metadata = metadata
        let now = Date()
        let record = PlaybackAssociationStore.Association(scope: "scope", playerID: "main", playlistID: "playlist", localTrackID: "local", musicItemID: "returned", localMetadata: metadata, reportedMetadata: metadata, learnedAt: reason == "expired" ? now.addingTimeInterval(-91 * 86400) : now)
        PlaybackAssociationStore.record(record, defaults: defaults)
        let original = member
        if reason == "changed" { member.metadata?.artist = "another artist" }
        var members = reason == "deleted" ? [] : [member]
        if reason == "conflict" { members.append(PendingQueueCorrelation(playlistItemID: UUID(), localTrackID: "competitor", queuedMusicItemID: "returned")) }
        #expect(PlaybackAssociationStore.validated(scope: "scope", playerID: "main", playlistID: "playlist", members: members, defaults: defaults, now: now).isEmpty)
        #expect(PlaybackAssociationStore.validated(scope: "scope", playerID: "main", playlistID: "playlist", members: [original], defaults: defaults, now: now).isEmpty)
    }
}
