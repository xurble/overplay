import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct VideoTrackPolicyTests {
    @Test("Video payloads are rejected by both repository intake paths")
    func rejectsVideoPersistence() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let video = try makeVideo()
        let snapshot = AppleMusicPlaylistTrackLoader.snapshot(from: video, playlistID: "source")
        #expect(throws: TrackImportError.self) {
            try TrackRecordRepository.upsert(snapshot, in: context)
        }
        #expect(throws: TrackImportError.self) {
            try TrackRecordRepository.upsert(catalogID: "video", libraryID: nil, title: "Video",
                artistName: "Artist", musicKitPlaybackData: JSONEncoder().encode(video), in: context)
        }
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("Cleanup removes legacy videos, all memberships and history, preserving songs and unknown records")
    func cleanup() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let video = TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        let song = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeSong()))
        let unknown = TrackRecord(catalogID: "unknown", title: "Unknown", artistName: "Artist")
        let malformed = TrackRecord(catalogID: "malformed", title: "Malformed", artistName: "Artist",
            musicKitPlaybackData: Data("invalid".utf8))
        for track in [video, song, unknown, malformed] { context.insert(track) }
        for _ in 0..<2 {
            context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: video.id, playthroughCount: 4))
        }
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: song.id, playthroughCount: 5))
        context.insert(HistoryEvent(trackID: video.id, eventType: .trackAdded, source: .user))
        context.insert(HistoryEvent(trackID: song.id, eventType: .trackAdded, source: .user))
        LocalPlaybackStateStore.save(LocalPlaybackState(playlistID: "source", musicItemID: "video",
            elapsedSeconds: 3, wasPlaying: false, updatedAt: .now, localTrackID: video.id.uuidString), to: defaults.defaults)
        PlaybackWaypointStore.save(PlaybackWaypoint(playlistID: "source", localTrackID: video.id.uuidString,
            positionSeconds: 3, recordedAt: .now), to: defaults.defaults)
        try context.save()

        #expect(try VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 1)
        let reloaded = ModelContext(container)
        #expect(Set(try TrackRecordRepository.allTracks(in: reloaded).map(\.id)) == Set([song.id, unknown.id, malformed.id]))
        #expect(try PlaylistItemRepository.allItems(in: reloaded).map(\.trackID) == [song.id])
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).map(\.trackID) == [song.id])
        #expect(LocalPlaybackStateStore.load(from: defaults.defaults) == nil)
        #expect(PlaybackWaypointStore.load(from: defaults.defaults) == nil)
        #expect(try VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 0)

        // An old device can deliver another legacy row after the first cleanup.
        context.insert(TrackRecord(catalogID: "late-video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo())))
        #expect(try VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 1)
    }

    @Test("Remote video identities remove legacy rows without playback data, including aliases")
    func cleanupUsingRemoteEvidence() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let video = TrackRecord(libraryID: "i.video", title: "Video", artistName: "Artist")
        video.identityAliases = ["video"]
        context.insert(video)
        #expect(try VideoTrackCleanupService.removeVideos(knownVideoIDs: ["video"], in: context) == 1)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("Mixed sync ignores videos and deletes legacy videos while importing songs", arguments: [PlaylistRole.oneTruePlaylist, .triageSource])
    func mixedSync(role: PlaylistRole) async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: role)
        context.insert(playlist)
        let video = try makeVideo()
        context.insert(TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(video)))
        let snapshots = [video, try makeSong()].map {
            AppleMusicPlaylistTrackLoader.snapshot(from: $0, playlistID: "source")
        }
        let result = try await PlaylistSyncService().reconcile(snapshots: snapshots,
            playlistRecord: playlist, syncedAt: .now, in: context)
        #expect(result.insertedCount == 1)
        #expect(result.skippedCount == 1)
        #expect(try TrackRecordRepository.allTracks(in: context).map(\.catalogID) == ["song"])
        #expect(try PlaylistItemRepository.allItems(in: context).count == 1)
    }

    @Test("Song-only copies preserve duplicates and video tracks cannot enter cached playback queues")
    func copiesAndCachedPlayback() throws {
        let video = try makeVideo()
        let song = try makeSong()
        #expect([video, song, song].filter(VideoTrackPolicy.isSong).map(\.id.rawValue) == ["song", "song"])
        #expect(AppleMusicPlaylistTrackLoader.videoMusicItemIDs(from: [video, song]) == ["video"])
        let record = TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(video))
        let item = PlaylistItemRecord(playlistID: UUID(), trackID: record.id)
        #expect(PlaybackQueueCoordinator.cachedEntry(localTrackID: record.id.uuidString,
            itemsByTrackID: [record.id: item], tracksByID: [record.id: record]) == nil)
    }

    @Test("Unchanged remote sync still purges legacy video data")
    func unchangedSync() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .oneTruePlaylist)
        context.insert(playlist)
        context.insert(TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo())))
        let adapter = VideoEvidenceSource(result: PlaylistSourceFetchResult(snapshots: [],
            skippedCount: 1, skippedReason: "remoteUnchanged", didFetchTracks: false))
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        let summary = try await service.syncPlaylist(playlist, in: context, skipWhenRemoteUnchanged: true)
        #expect(summary.skippedReason == "remoteUnchanged")
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("Source sync applies remote video evidence before reconciliation")
    func remoteEvidenceSync() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .oneTruePlaylist)
        context.insert(playlist)
        context.insert(TrackRecord(catalogID: "video", title: "Video", artistName: "Artist"))
        let adapter = VideoEvidenceSource(result: PlaylistSourceFetchResult(snapshots: [],
            skippedCount: 1, skippedReason: "nonSongEntries", videoMusicItemIDs: ["video"]))
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        _ = try await service.syncPlaylist(playlist, in: context, runIdentityMerge: false)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("Periodic cleanup runs even without linked playlists")
    func periodicCleanup() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo())))
        await PeriodicPlaylistSyncService().syncLinkedPlaylists(context: context)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    private func makeVideo() throws -> Track {
        let json = #"{"id":"video","type":"music-videos","attributes":{"name":"Video","artistName":"Artist","genreNames":[],"durationInMillis":100000}}"#
        return .musicVideo(try JSONDecoder().decode(MusicVideo.self, from: Data(json.utf8)))
    }

    private func makeSong() throws -> Track {
        let json = #"{"id":"song","type":"songs","attributes":{"name":"Song","artistName":"Artist","albumName":"Album","genreNames":[],"durationInMillis":180000}}"#
        return .song(try JSONDecoder().decode(Song.self, from: Data(json.utf8)))
    }
}

@MainActor
private struct VideoEvidenceSource: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic
    let result: PlaylistSourceFetchResult

    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink] { [] }

    func fetchTrackSnapshots(playlistID: String, playlistName: String?, playlistRecord: PlaylistRecord?,
        skipWhenRemoteUnchanged: Bool, in context: ModelContext) async throws -> PlaylistSourceFetchResult {
        result
    }
}
