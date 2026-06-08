import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist presentation builder")
struct PlaylistPresentationBuilderTests {
    @Test("orders active playlist summaries by role and case-insensitive title")
    func ordersActivePlaylistSummaries() {
        let inactive = PlaylistRecord(musicPlaylistID: "inactive", name: "Hidden", role: .oneTruePlaylist, isActive: false)
        let triageB = PlaylistRecord(musicPlaylistID: "triage-b", name: "zeta", role: .triage)
        let triageA = PlaylistRecord(musicPlaylistID: "triage-a", name: "Alpha", role: .triage)
        let oneTrue = PlaylistRecord(musicPlaylistID: "one", name: "Main", role: .oneTruePlaylist)

        let summaries = builder(playlists: [inactive, triageB, triageA, oneTrue]).activePlaylistSummaries()

        #expect(summaries.map(\.title) == ["Main", "Alpha", "zeta"])
        #expect(summaries.map(\.musicPlaylistID) == ["one", "triage-a", "triage-b"])
    }

    @Test("playlist summaries include counts role grouping and current playback intent")
    func playlistSummariesIncludeCountsAndCurrentIntent() {
        let playlist = PlaylistRecord(musicPlaylistID: "triage", name: "Inbox", role: .triage)
        let playableTrack = TrackRecord(title: "Ready", artistName: "Artist")
        let evictedTrack = TrackRecord(title: "Gone", artistName: "Artist")
        let items = [
            PlaylistItemRecord(playlistID: playlist.id, trackID: playableTrack.id),
            PlaylistItemRecord(playlistID: playlist.id, trackID: evictedTrack.id, evictedAt: .now)
        ]

        let summary = builder(
            playlists: [playlist],
            items: items,
            tracks: [playableTrack, evictedTrack],
            currentPlaylistID: "triage"
        )
        .summary(for: playlist)

        #expect(summary.activeTrackCount == 2)
        #expect(summary.playableTrackCount == 1)
        #expect(summary.displayPriority == 1)
        #expect(summary.iconIntent == .currentPlayback)
    }

    @Test("representative artwork prefers first playable item with artwork")
    func representativeArtwork() {
        let playlist = PlaylistRecord(musicPlaylistID: "one", name: "Main", role: .oneTruePlaylist)
        let noArtwork = TrackRecord(title: "No Art", artistName: "Artist")
        let artwork = TrackRecord(title: "Art", artistName: "Artist", artworkURLTemplate: "https://example.com/art.jpg")
        let evictedArtwork = TrackRecord(title: "Evicted", artistName: "Artist", artworkURLTemplate: "https://example.com/evicted.jpg")
        let items = [
            PlaylistItemRecord(playlistID: playlist.id, trackID: evictedArtwork.id, sortOrder: 0, evictedAt: .now),
            PlaylistItemRecord(playlistID: playlist.id, trackID: noArtwork.id, sortOrder: 1),
            PlaylistItemRecord(playlistID: playlist.id, trackID: artwork.id, sortOrder: 2)
        ]

        let summary = builder(playlists: [playlist], items: items, tracks: [noArtwork, artwork, evictedArtwork])
            .summary(for: playlist)

        #expect(summary.artworkURLString == "https://example.com/art.jpg")
    }

    @Test("track summaries include playable tracks in playlist order with health")
    func trackSummaries() {
        let playlistID = UUID()
        let firstTrack = TrackRecord(title: "First", artistName: "Artist", albumTitle: "Album")
        let secondTrack = TrackRecord(title: "Second", artistName: "Artist")
        let evictedTrack = TrackRecord(title: "Evicted", artistName: "Artist")
        let items = [
            PlaylistItemRecord(playlistID: playlistID, trackID: secondTrack.id, sortOrder: 2, skipCount: 2),
            PlaylistItemRecord(playlistID: playlistID, trackID: firstTrack.id, sortOrder: 1),
            PlaylistItemRecord(playlistID: playlistID, trackID: evictedTrack.id, sortOrder: 3, evictedAt: .now)
        ]

        let summaries = builder(items: items, tracks: [firstTrack, secondTrack, evictedTrack], evictAfterSkips: 3)
            .trackSummaries(forPlaylistID: playlistID)

        #expect(summaries.map(\.title) == ["First", "Second"])
        #expect(summaries.first?.subtitle == "Artist - Album")
        #expect(summaries.last?.skipCountLabel == "2 skips")
    }

    @Test("empty builder returns empty presentation state")
    func emptyState() {
        let builder = builder()

        #expect(builder.activePlaylistSummaries().isEmpty)
        #expect(builder.trackSummaries(forPlaylistID: UUID()).isEmpty)
        #expect(builder.dashboardSummary(forPlaylistID: UUID()) == .empty)
    }

    private func builder(
        playlists: [PlaylistRecord] = [],
        items: [PlaylistItemRecord] = [],
        tracks: [TrackRecord] = [],
        currentPlaylistID: String? = nil,
        evictAfterSkips: Int = 3
    ) -> PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: playlists,
            items: items,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID,
            evictAfterSkips: evictAfterSkips
        )
    }
}
