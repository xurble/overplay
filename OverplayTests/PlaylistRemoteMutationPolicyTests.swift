import Foundation
import Testing
@testable import Overplay

@Suite("Playlist remote mutation policy")
@MainActor
struct PlaylistRemoteMutationPolicyTests {
    @Test("managed one true playlist evictions may delete remotely")
    func managedOneTruePlaylistEvictionsMayDeleteRemotely() {
        let playlist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist,
            writePolicy: .managed
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            evictedAt: Date(timeIntervalSince1970: 100),
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        )

        #expect(PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(
            item: item,
            playlist: playlist
        ))
    }

    @Test("incoming only one true playlist evictions do not delete remotely")
    func incomingOnlyOneTruePlaylistEvictionsDoNotDeleteRemotely() {
        let playlist = PlaylistRecord(
            musicPlaylistID: "source-playlist",
            name: "Source",
            role: .oneTruePlaylist,
            writePolicy: .incomingOnly
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            evictedAt: Date(timeIntervalSince1970: 100),
            evictionReason: .manual,
            evictionSource: .user
        )

        #expect(!PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(
            item: item,
            playlist: playlist
        ))
    }

    @Test("triage playlist evictions do not delete remotely")
    func triagePlaylistEvictionsDoNotDeleteRemotely() {
        let playlist = PlaylistRecord(
            musicPlaylistID: "triage-playlist",
            name: "Triage",
            role: .triage,
            writePolicy: .managed
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID(),
            evictedAt: Date(timeIntervalSince1970: 100),
            evictionReason: .manual,
            evictionSource: .user
        )

        #expect(!PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(
            item: item,
            playlist: playlist
        ))
    }

    @Test("active items do not delete remotely")
    func activeItemsDoNotDeleteRemotely() {
        let playlist = PlaylistRecord(
            musicPlaylistID: "main-playlist",
            name: "Main",
            role: .oneTruePlaylist,
            writePolicy: .managed
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: UUID()
        )

        #expect(!PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(
            item: item,
            playlist: playlist
        ))
    }
}
