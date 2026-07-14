import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("New model repositories")
struct NewModelRepositoryTests {
    @Test("playlist upsert creates then updates by Apple Music ID")
    func playlistUpsertCreatesThenUpdatesByAppleMusicID() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let inserted = try PlaylistRepository.upsert(
            musicPlaylistID: "playlist-1",
            name: "Original",
            role: .triage,
            in: context
        )
        let updated = try PlaylistRepository.upsert(
            musicPlaylistID: "playlist-1",
            name: "One True Playlist",
            role: .oneTruePlaylist,
            in: context
        )
        let playlists = try PlaylistRepository.allPlaylists(in: context)

        #expect(playlists.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.name == "One True Playlist")
        #expect(updated.role == .oneTruePlaylist)
        #expect(updated.writePolicy == .managed)
    }

    @Test("setting one true playlist stores incoming only write policy")
    func settingOneTruePlaylistStoresIncomingOnlyWritePolicy() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try SettingsRepository.selectPlaylist(
            AppleMusicPlaylist(id: "source-playlist", name: "Source", trackCount: 10),
            writePolicy: .incomingOnly,
            in: context
        )
        let settings = try SettingsRepository.settings(in: context)
        let playlist = try #require(try PlaylistRepository.oneTruePlaylist(in: context))

        #expect(settings.selectedPlaylistID == "source-playlist")
        #expect(playlist.role == .oneTruePlaylist)
        #expect(playlist.writePolicy == .incomingOnly)
        #expect(!playlist.allowsRemoteWrites)
    }

    @Test("setting one true playlist demotes previous one true playlist")
    func settingOneTruePlaylistDemotesPreviousOneTruePlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try PlaylistRepository.setOneTruePlaylist(
            AppleMusicPlaylist(id: "playlist-1", name: "First", trackCount: 10),
            in: context
        )
        let selected = try PlaylistRepository.setOneTruePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Second", trackCount: 12),
            in: context
        )
        let playlists = try PlaylistRepository.allPlaylists(in: context)

        #expect(selected.musicPlaylistID == "playlist-2")
        #expect(playlists.count == 2)
        #expect(playlists.filter { $0.role == .oneTruePlaylist }.count == 1)
        let firstPlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-1", in: context)
        #expect(firstPlaylist?.role == .triage)
    }

    @Test("adding triage playlist does not change existing one true playlist")
    func addingTriagePlaylistDoesNotChangeExistingOneTruePlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try SettingsRepository.selectPlaylist(
            AppleMusicPlaylist(id: "playlist-1", name: "Main", trackCount: 10),
            in: context
        )
        try PlaylistRepository.addTriagePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Triage", trackCount: 12),
            in: context
        )
        let settings = try SettingsRepository.settings(in: context)
        let fetchedOneTruePlaylist = try PlaylistRepository.oneTruePlaylist(in: context)
        let oneTruePlaylist = try #require(fetchedOneTruePlaylist)

        #expect(settings.selectedPlaylistID == "playlist-1")
        #expect(oneTruePlaylist.musicPlaylistID == "playlist-1")
        let triagePlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-2", in: context)
        #expect(triagePlaylist?.role == .triage)
    }

    @Test("deactivating triage playlist hides it from active playlists")
    func deactivatingTriagePlaylistHidesItFromActivePlaylists() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let playlist = try PlaylistRepository.addTriagePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Triage", trackCount: 12),
            in: context
        )
        try PlaylistRepository.deactivateTriagePlaylist(playlist, in: context)
        let activePlaylists = try PlaylistRepository.activePlaylists(in: context)
        let fetchedPlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-2", in: context)

        #expect(activePlaylists.isEmpty)
        #expect(fetchedPlaylist?.isActive == false)
    }

    @Test("playlist repository fetches by predicate scoped identifiers")
    func playlistRepositoryFetchesByPredicateScopedIdentifiers() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oneTruePlaylistID = UUID()
        let triagePlaylistID = UUID()
        let inactivePlaylistID = UUID()
        let oneTruePlaylist = PlaylistRecord(
            id: oneTruePlaylistID,
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist,
            sortOrder: 1
        )
        let triagePlaylist = PlaylistRecord(
            id: triagePlaylistID,
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage,
            sortOrder: 0
        )
        let inactivePlaylist = PlaylistRecord(
            id: inactivePlaylistID,
            musicPlaylistID: "playlist-3",
            name: "Hidden",
            role: .triage,
            isActive: false
        )
        context.insert(oneTruePlaylist)
        context.insert(triagePlaylist)
        context.insert(inactivePlaylist)

        let activePlaylists = try PlaylistRepository.activePlaylists(in: context)
        let fetchedByID = try PlaylistRepository.playlist(id: triagePlaylistID, in: context)
        let fetchedByMusicID = try PlaylistRepository.playlist(musicPlaylistID: "playlist-1", in: context)
        let fetchedOneTruePlaylist = try PlaylistRepository.oneTruePlaylist(in: context)

        #expect(activePlaylists.map(\.id) == [triagePlaylistID, oneTruePlaylistID])
        #expect(fetchedByID?.id == triagePlaylistID)
        #expect(fetchedByMusicID?.id == oneTruePlaylistID)
        #expect(fetchedOneTruePlaylist?.id == oneTruePlaylistID)
        #expect(try PlaylistRepository.playlist(id: UUID(), in: context) == nil)
    }

    @Test("track record upsert creates then updates without changing identity")
    func trackRecordUpsertCreatesThenUpdatesWithoutChangingIdentity() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let firstSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-1",
            playlistID: "playlist-1",
            title: "Original",
            artistName: "Sample Artist",
            albumTitle: "Original Album",
            artworkURLTemplate: nil,
            durationSeconds: 180,
            musicKitPlaybackData: Data("cached-playback".utf8)
        )
        let inserted = try TrackRecordRepository.upsert(firstSnapshot, in: context)

        let secondSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-2",
            playlistID: "playlist-1",
            title: "Updated",
            artistName: "Sample Artist",
            albumTitle: "Updated Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 210
        )
        let updated = try TrackRecordRepository.upsert(secondSnapshot, in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.title == "Updated")
        #expect(updated.albumTitle == "Updated Album")
        #expect(updated.artworkURLTemplate == "https://example.com/artwork.jpg")
        #expect(updated.durationSeconds == 210)
        #expect(updated.musicKitPlaybackData == Data("cached-playback".utf8))

        let missingArtworkSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-3",
            playlistID: "playlist-1",
            title: "Updated Again",
            artistName: "Sample Artist",
            albumTitle: "Updated Album",
            artworkURLTemplate: nil,
            durationSeconds: 220
        )
        let retainedArtwork = try TrackRecordRepository.upsert(missingArtworkSnapshot, in: context)

        #expect(retainedArtwork.artworkURLTemplate == "https://example.com/artwork.jpg")
        #expect(retainedArtwork.durationSeconds == 220)

        let changedArtworkSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-4",
            playlistID: "playlist-1",
            title: "Updated Again",
            artistName: "Sample Artist",
            albumTitle: "Updated Album",
            artworkURLTemplate: "https://example.com/changed.jpg",
            durationSeconds: 230
        )
        let unchangedArtwork = try TrackRecordRepository.upsert(changedArtworkSnapshot, in: context)

        #expect(unchangedArtwork.artworkURLTemplate == "https://example.com/artwork.jpg")
        #expect(unchangedArtwork.durationSeconds == 230)
    }

    @Test("catalog manual add and library sync collapse to one track record")
    func catalogManualAddAndLibrarySyncCollapseToOneTrackRecord() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let manualAdd = try TrackRecordRepository.upsert(
            catalogID: "1440833098",
            libraryID: nil,
            title: "Song",
            artistName: "Artist",
            in: context
        )

        let librarySyncSnapshot = TrackSnapshot(
            id: "i.abc123",
            catalogID: "1440833098",
            libraryID: "i.abc123",
            playlistEntryID: nil,
            playlistID: "playlist-1",
            title: "Song",
            artistName: "Artist",
            albumTitle: nil,
            artworkURLTemplate: nil,
            durationSeconds: 180,
            musicKitPlaybackData: Data("cached-playback".utf8)
        )
        let synced = try TrackRecordRepository.upsert(librarySyncSnapshot, in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(synced.id == manualAdd.id)
        #expect(synced.catalogID == "1440833098")
        #expect(synced.libraryID == "i.abc123")
        #expect(synced.musicKitPlaybackData == Data("cached-playback".utf8))
    }

    @Test("snapshot upsert does not mirror a single-domain ID into both fields")
    func snapshotUpsertDoesNotMirrorASingleDomainIDIntoBothFields() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let librarySnapshot = TrackSnapshot(
            id: "i.abc123",
            catalogID: nil,
            libraryID: nil,
            playlistEntryID: nil,
            playlistID: "playlist-1",
            title: "Song",
            artistName: "Artist",
            albumTitle: nil,
            artworkURLTemplate: nil,
            durationSeconds: nil
        )
        let record = try TrackRecordRepository.upsert(librarySnapshot, in: context)

        #expect(record.libraryID == "i.abc123")
        #expect(record.catalogID == nil)
    }

    @Test("upsert does not erase a known identifier with nil")
    func upsertDoesNotEraseAKnownIdentifierWithNil() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try TrackRecordRepository.upsert(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            in: context
        )
        let updated = try TrackRecordRepository.upsert(
            catalogID: nil,
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            in: context
        )
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(updated.catalogID == "1440833098")
        #expect(updated.libraryID == "i.abc123")
    }

    @Test("upsert heals a legacy mirrored catalog ID")
    func upsertHealsALegacyMirroredCatalogID() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        context.insert(TrackRecord(
            catalogID: "i.abc123",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist"
        ))

        let healed = try TrackRecordRepository.upsert(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            in: context
        )
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(healed.catalogID == "1440833098")
        #expect(healed.libraryID == "i.abc123")
    }

    @Test("playlist item upsert creates then updates membership by playlist and track")
    func playlistItemUpsertCreatesThenUpdatesMembershipByPlaylistAndTrack() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()

        let inserted = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-1",
            in: context
        )
        inserted.skipCount = 2

        let updated = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-2",
            in: context
        )
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(items.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.musicPlaylistEntryID == "entry-2")
        #expect(updated.skipCount == 2)
    }

    @Test("playlist items are returned in created order")
    func playlistItemsAreReturnedInCreatedOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()

        let last = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-last",
            sortOrder: 2,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let first = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-first",
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let middle = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-middle",
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(last)
        context.insert(first)
        context.insert(middle)

        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(items.map(\.id) == [first.id, middle.id, last.id])
    }

    @Test("playlist item repository fetches scoped items by predicate")
    func playlistItemRepositoryFetchesScopedItemsByPredicate() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let otherPlaylistID = UUID()
        let playableTrackID = UUID()
        let evictedTrackID = UUID()
        let playableItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: playableTrackID,
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let evictedItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: evictedTrackID,
            sortOrder: 0,
            evictedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let otherPlaylistItem = PlaylistItemRecord(
            playlistID: otherPlaylistID,
            trackID: UUID()
        )
        context.insert(playableItem)
        context.insert(evictedItem)
        context.insert(otherPlaylistItem)

        let allPlaylistItems = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)
        let playableItems = try PlaylistItemRepository.playableItems(forPlaylistID: playlistID, in: context)
        let fetchedItem = try PlaylistItemRepository.item(
            playlistID: playlistID,
            trackID: playableTrackID,
            in: context
        )

        #expect(allPlaylistItems.map(\.id) == [playableItem.id, evictedItem.id])
        #expect(playableItems.map(\.id) == [playableItem.id])
        #expect(fetchedItem?.id == playableItem.id)
        #expect(try PlaylistItemRepository.item(id: evictedItem.id, in: context)?.id == evictedItem.id)
    }

    @Test("playlist item repository removes duplicate memberships")
    func playlistItemRepositoryRemovesDuplicateMemberships() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()
        let keptItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-kept",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicateItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-duplicate",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let otherItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-other",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        context.insert(duplicateItem)
        context.insert(otherItem)
        context.insert(keptItem)

        let removedCount = try PlaylistItemRepository.removeDuplicateItems(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(removedCount == 1)
        #expect(items.map(\.id) == [keptItem.id, otherItem.id])
    }

    @Test("track repository fetches scoped tracks by predicate")
    func trackRepositoryFetchesScopedTracksByPredicate() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let firstTrackID = UUID()
        let secondTrackID = UUID()
        let firstTrack = TrackRecord(
            id: firstTrackID,
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "First",
            artistName: "Sample Artist"
        )
        let secondTrack = TrackRecord(
            id: secondTrackID,
            catalogID: "catalog-2",
            libraryID: "library-2",
            title: "Second",
            artistName: "Sample Artist"
        )
        context.insert(firstTrack)
        context.insert(secondTrack)

        let fetchedTracks = try TrackRecordRepository.tracks(ids: [secondTrackID, firstTrackID, firstTrackID], in: context)
        let fetchedByID = try TrackRecordRepository.track(id: firstTrackID, in: context)
        let fetchedByMusicID = try TrackRecordRepository.track(musicItemID: "library-2", in: context)

        #expect(Set(fetchedTracks.map(\.id)) == [firstTrackID, secondTrackID])
        #expect(fetchedByID?.id == firstTrackID)
        #expect(fetchedByMusicID?.id == secondTrackID)
        #expect(try TrackRecordRepository.tracks(ids: [], in: context).isEmpty)
    }

    @Test("playlist items can be fetched for multiple playlist IDs")
    func playlistItemsCanBeFetchedForMultiplePlaylistIDs() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let firstPlaylistID = UUID()
        let secondPlaylistID = UUID()
        let thirdPlaylistID = UUID()
        let firstItem = PlaylistItemRecord(playlistID: firstPlaylistID, trackID: UUID())
        let secondItem = PlaylistItemRecord(playlistID: secondPlaylistID, trackID: UUID())
        let unrelatedItem = PlaylistItemRecord(playlistID: thirdPlaylistID, trackID: UUID())
        context.insert(firstItem)
        context.insert(secondItem)
        context.insert(unrelatedItem)

        let items = try PlaylistItemRepository.items(
            forPlaylistIDs: [firstPlaylistID, secondPlaylistID],
            in: context
        )

        #expect(Set(items.map(\.id)) == [firstItem.id, secondItem.id])
        #expect(try PlaylistItemRepository.items(forPlaylistIDs: [], in: context).isEmpty)
    }

    @Test("reset playlist stats clears item counters and eviction state")
    func resetPlaylistStatsClearsItemCountersAndEvictionState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = PlaylistItemRecord(
            playlistID: UUID(),
            trackID: UUID(),
            skipCount: 4,
            playthroughCount: 2,
            lastPlayedAt: Date(timeIntervalSince1970: 100),
            lastSkippedAt: Date(timeIntervalSince1970: 200),
            evictedAt: Date(timeIntervalSince1970: 300),
            evictionReason: .skipCount,
            evictionSource: .playbackRule,
            protected: true
        )
        context.insert(item)

        try PlaylistItemRepository.resetAllStats(in: context)

        #expect(item.skipCount == 0)
        #expect(item.playthroughCount == 0)
        #expect(item.lastPlayedAt == nil)
        #expect(item.lastSkippedAt == nil)
        #expect(item.evictedAt == nil)
        #expect(item.evictionReason == nil)
        #expect(item.evictionSource == nil)
        #expect(!item.protected)
    }

    @Test("event repository writes history events")
    func eventRepositoryWritesHistoryEvents() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()

        let event = EventRepository.logHistory(
            playlistID: playlistID,
            trackID: trackID,
            eventType: .promoted,
            source: .user,
            remoteMutationStatus: .succeeded,
            message: "Promoted from triage",
            in: context
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(events.count == 1)
        #expect(events.first?.id == event.id)
        #expect(events.first?.playlistID == playlistID)
        #expect(events.first?.trackID == trackID)
        #expect(events.first?.eventType == .promoted)
        #expect(events.first?.source == .user)
        #expect(events.first?.remoteMutationStatus == .succeeded)
    }

    @Test("triage playlist playback uses linked playlist state")
    func triagePlaylistPlaybackUsesLinkedPlaylistState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let settings = OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        )
        let triagePlaylist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        context.insert(settings)
        context.insert(triagePlaylist)

        await controller.playPlaylist(triagePlaylist, settings: settings, context: context)

        #expect(controller.currentPlaylistID == nil)
        #expect(controller.statusMessage == "No locally cached playable tracks for Triage. Sync this playlist before playing.")
    }
}
