import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Track identity merge service")
struct TrackIdentityMergeServiceTests {
    @Test("records sharing an identifier collapse into the oldest record")
    func recordsSharingAnIdentifierCollapseIntoTheOldestRecord() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            musicKitPlaybackData: Data("cached-playback".utf8),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(canonical)
        context.insert(duplicate)
        let duplicateID = duplicate.id

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.localTrackIDMapping == [duplicateID.uuidString: canonical.id.uuidString])
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == canonical.id)
        #expect(canonical.catalogID == "1440833098")
        #expect(canonical.libraryID == "i.abc123")
        #expect(canonical.musicKitPlaybackData == Data("cached-playback".utf8))
    }

    @Test("identifier spelling cannot move an identifier into a different domain")
    func identifierSpellingDoesNotEstablishDomain() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let catalog = TrackRecord(catalogID: "i.same", title: "Catalog", artistName: "Artist")
        let library = TrackRecord(libraryID: "i.same", title: "Library", artistName: "Artist")
        context.insert(catalog)
        context.insert(library)
        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.mergedTrackCount == 0)
        #expect(catalog.catalogID == "i.same")
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
    }

    @Test("playlist items repoint to the canonical track and merge stats")
    func playlistItemsRepointToTheCanonicalTrackAndMergeStats() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let canonicalItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: canonical.id,
            skipCount: 3,
            playthroughCount: 2,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicateItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: duplicate.id,
            skipCount: 2,
            playthroughCount: 1,
            lastPlayedAt: Date(timeIntervalSince1970: 300),
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(canonicalItem)
        context.insert(duplicateItem)

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.mergedItemCount == 1)
        #expect(items.count == 1)
        #expect(items.first?.id == canonicalItem.id)
        #expect(canonicalItem.trackID == canonical.id)
        #expect(canonicalItem.skipCount == 5)
        #expect(canonicalItem.playthroughCount == 3)
        #expect(canonicalItem.lastPlayedAt == Date(timeIntervalSince1970: 300))
    }

    @Test("items in different playlists merge globally after repointing")
    func itemsInDifferentPlaylistsMergeAfterRepointing() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let firstPlaylistID = UUID()
        let secondPlaylistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let firstItem = PlaylistItemRecord(
            playlistID: firstPlaylistID,
            trackID: canonical.id,
            skipCount: 3
        )
        let secondItem = PlaylistItemRecord(
            playlistID: secondPlaylistID,
            trackID: duplicate.id,
            skipCount: 2
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(firstItem)
        context.insert(secondItem)

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.mergedItemCount == 1)
        let items = try PlaylistItemRepository.allItems(in: context)
        #expect(items.count == 1)
        #expect(items.first?.skipCount == 5)
        #expect(items.first?.trackID == canonical.id)
    }

    @Test("history events repoint to the canonical track")
    func historyEventsRepointToTheCanonicalTrack() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let event = HistoryEvent(
            trackID: duplicate.id,
            eventType: .skipCounted,
            source: .playback
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(event)

        try await TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(event.trackID == canonical.id)
    }

    @Test("merged donors join the keeper's listen-ledger lineage")
    func mergedDonorsJoinLedgerLineage() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(catalogID: "1440833098", title: "Song", artistName: "Artist",
                                    createdAt: Date(timeIntervalSince1970: 10))
        let duplicate = TrackRecord(catalogID: "1440833098", libraryID: "i.abc123", title: "Song", artistName: "Artist",
                                    createdAt: Date(timeIntervalSince1970: 20))
        context.insert(canonical)
        context.insert(duplicate)
        let duplicateID = duplicate.id
        try ListenLedger.record(.playthrough, trackID: duplicateID, sessionID: "donor-play", source: .playback, in: context)

        try await TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(canonical.absorbedTrackIDs == [duplicateID.uuidString])
        #expect(try ListenLedger.counts(forTrackID: canonical.id, in: context).playthroughs == 1)
    }

    @Test("merge is idempotent")
    func mergeIsIdempotent() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(PlaylistItemRecord(playlistID: playlistID, trackID: canonical.id, skipCount: 1))
        context.insert(PlaylistItemRecord(playlistID: playlistID, trackID: duplicate.id, skipCount: 2))

        let firstSummary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        let secondSummary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(firstSummary.didChange)
        #expect(secondSummary == TrackIdentityMergeService.MergeSummary())
        #expect(items.count == 1)
        #expect(items.first?.skipCount == 3)
    }

    @Test("distinct songs are untouched")
    func distinctSongsAreUntouched() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(TrackRecord(catalogID: "111", title: "One", artistName: "Artist"))
        context.insert(TrackRecord(catalogID: "222", libraryID: "i.two", title: "Two", artistName: "Artist"))
        context.insert(TrackRecord(libraryID: "i.three", title: "Three", artistName: "Artist"))

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(summary == TrackIdentityMergeService.MergeSummary())
        #expect(try TrackRecordRepository.allTracks(in: context).count == 3)
    }

    @Test("transitive identifier chains merge into one record")
    func transitiveIdentifierChainsMergeIntoOneRecord() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let second = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let third = TrackRecord(
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        context.insert(first)
        context.insert(second)
        context.insert(third)

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(summary.mergedTrackCount == 2)
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == first.id)
    }
    @Test("conflicting opaque bridges cannot merge an unrelated catalog recording")
    func documentedEmptyRelationshipBreaksOpaqueBridge() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let upload = TrackRecord(libraryID: "i.same", title: "Upload", artistName: "Artist")
        upload.hasDocumentedIdentity = true
        let legacy = TrackRecord(catalogID: "123", libraryID: "i.same", title: "Legacy", artistName: "Artist")
        let unrelated = TrackRecord(catalogID: "123", title: "Different recording", artistName: "Other artist")
        for track in [upload, legacy, unrelated] { context.insert(track) }
        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.mergedTrackCount == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 3)
        #expect(unrelated.catalogID == "123")
        #expect(upload.catalogID == nil)
    }

}
