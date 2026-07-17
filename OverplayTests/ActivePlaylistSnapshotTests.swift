import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Active playlist snapshot")
struct ActivePlaylistSnapshotTests {
    @Test("builds ordered rows from local playback order without mutating sort order")
    func buildsOrderedRowsFromLocalPlaybackOrder() {
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let firstTrack = TrackRecord(
            catalogID: "catalog-first",
            libraryID: "library-first",
            title: "First",
            artistName: "Artist",
            albumTitle: "Album",
            artworkURLTemplate: "https://example.com/first.jpg"
        )
        let secondTrack = TrackRecord(
            catalogID: "catalog-second",
            libraryID: "library-second",
            title: "Second",
            artistName: "Artist"
        )
        let firstItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: firstTrack.id,
            sortOrder: 10,
            skipCount: 1,
            playthroughCount: 2,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let secondItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: secondTrack.id,
            sortOrder: 20,
            skipCount: 3,
            protected: true,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let state = PlaybackOrderState(
            playerID: "player",
            musicPlaylistID: playlist.musicPlaylistID,
            orderedTrackIDs: [secondTrack.id.uuidString, firstTrack.id.uuidString]
        )

        let snapshot = ActivePlaylistSnapshot(
            playlist: playlist,
            items: [firstItem, secondItem],
            tracks: [firstTrack, secondTrack],
            playbackOrderState: state,
            currentLocalTrackID: secondTrack.id.uuidString,
            currentMusicItemID: "catalog-second"
        )

        #expect(snapshot.rows.map(\.id) == [secondItem.id, firstItem.id])
        #expect(snapshot.rows.first?.title == "Second")
        #expect(snapshot.rows.first?.skipCount == 3)
        #expect(snapshot.rows.first?.isProtected == true)
        #expect(snapshot.rows.first?.isCurrent == true)
        #expect(snapshot.rows.last?.playthroughCount == 2)
        #expect(snapshot.rows.last?.artworkURLString == "https://example.com/first.jpg")
        #expect(firstItem.sortOrder == 10)
        #expect(secondItem.sortOrder == 20)
    }

    @Test("updating current row preserves row identity")
    func updatingCurrentRowPreservesRowIdentity() {
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let firstTrack = TrackRecord(catalogID: "first", libraryID: "first", title: "First", artistName: "Artist")
        let secondTrack = TrackRecord(catalogID: "second", libraryID: "second", title: "Second", artistName: "Artist")
        let firstItem = PlaylistItemRecord(playlistID: playlist.id, trackID: firstTrack.id)
        let secondItem = PlaylistItemRecord(playlistID: playlist.id, trackID: secondTrack.id)
        let snapshot = ActivePlaylistSnapshot(
            playlist: playlist,
            items: [firstItem, secondItem],
            tracks: [firstTrack, secondTrack],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistItemID: firstItem.id
        )

        let updated = snapshot.updatingCurrentRow(
            currentPlaylistItemID: secondItem.id,
            currentLocalTrackID: secondTrack.id.uuidString,
            currentMusicItemID: "second"
        )

        #expect(updated.rows.map(\.id) == snapshot.rows.map(\.id))
        #expect(updated.rows.first { $0.id == firstItem.id }?.isCurrent == false)
        #expect(updated.rows.first { $0.id == secondItem.id }?.isCurrent == true)
    }

    @Test("rebuilt snapshot reflects track action mutations")
    func rebuiltSnapshotReflectsTrackActionMutations() {
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(catalogID: "track", libraryID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 1,
            playthroughCount: 0
        )

        item.skipCount += 1
        item.playthroughCount += 1
        item.skipCount = 0
        item.protected = true
        item.evictedAt = Date(timeIntervalSince1970: 100)

        let snapshot = ActivePlaylistSnapshot(
            playlist: playlist,
            items: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistItemID: item.id
        )

        #expect(snapshot.rows.first?.skipCount == 0)
        #expect(snapshot.rows.first?.playthroughCount == 1)
        #expect(snapshot.rows.first?.isProtected == true)
        #expect(snapshot.rows.first?.isEvicted == true)
        #expect(snapshot.rows.first?.isPlayable == false)
    }
}
