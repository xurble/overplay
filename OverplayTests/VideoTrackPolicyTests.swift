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
    func cleanup() async throws {
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
        PlaybackWaypointStore.save(PlaybackWaypoint(playlistID: "source", localTrackID: video.id.uuidString,
            positionSeconds: 3, recordedAt: .now), to: defaults.defaults)
        try context.save()

        #expect(try await VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 1)
        let reloaded = ModelContext(container)
        #expect(Set(try TrackRecordRepository.allTracks(in: reloaded).map(\.id)) == Set([song.id, unknown.id, malformed.id]))
        #expect(try PlaylistItemRepository.allItems(in: reloaded).map(\.trackID) == [song.id])
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).map(\.trackID) == [song.id])
        #expect(PlaybackWaypointStore.load(from: defaults.defaults) == nil)
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 0)

        // An old device can deliver another legacy row after the first cleanup.
        context.insert(TrackRecord(catalogID: "late-video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo())))
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, defaults: defaults.defaults) == 1)
    }

    /// A song merged into a video went with it: a membership or history event
    /// of that song would otherwise wait for a survivor that is gone
    /// (`LOC-002`). One that another merge kept stays.
    @Test("Cleanup removes rows of tracks a video absorbed, unless another merge kept them")
    func cleanupRemovesRowsOfAbsorbedTracks() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let video = TrackRecord(libraryID: "i.video", title: "Video", artistName: "Artist")
        video.confirmedAliases = [.catalog("video")]
        let song = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        context.insert(video)
        context.insert(song)
        let absorbed = UUID()
        let alsoKept = UUID()
        try ListenLedger.recordLineage(keeper: video.id, donor: absorbed, in: context)
        try ListenLedger.recordLineage(keeper: video.id, donor: alsoKept, in: context)
        try ListenLedger.recordLineage(keeper: song.id, donor: alsoKept, in: context)
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: absorbed))
        context.insert(HistoryEvent(trackID: absorbed, eventType: .trackAdded, source: .user))
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: alsoKept))
        try context.save()

        #expect(try await VideoTrackCleanupService.removeVideos(knownVideoIDs: ["video"], in: context) == 1)
        #expect(try PlaylistItemRepository.allItems(in: context).map(\.trackID) == [alsoKept])
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
    }

    @Test("Remote video identities remove legacy rows without playback data, including aliases")
    func cleanupUsingRemoteEvidence() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let video = TrackRecord(libraryID: "i.video", title: "Video", artistName: "Artist")
        video.confirmedAliases = [.catalog("video")]
        context.insert(video)
        #expect(try await VideoTrackCleanupService.removeVideos(knownVideoIDs: ["video"], in: context) == 1)
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

    /// PF-9: each track's playback data is decoded once per launch, read
    /// without filling the shared cache; a new launch inspects it again.
    @Test("The playback-data scan inspects each track once per launch and keeps nothing resident")
    func scanOncePerLaunchWithoutCaching() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let directory = URL.temporaryDirectory.appendingPathComponent("VideoScan-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DevicePlaybackCache(directory: directory)
        let track = TrackRecord(catalogID: "later-video", title: "Song", artistName: "Artist")
        context.insert(track)
        try context.save()
        writer.set(try JSONEncoder().encode(makeSong()), for: track.id)

        let reader = DevicePlaybackCache(directory: directory)
        let launch = VideoPlaybackScan(cache: reader)
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: launch) == 0)
        // The scan read the file but kept nothing: with the file gone, so is the data.
        writer.set(nil, for: track.id)
        #expect(reader.data(for: track.id) == nil)

        // Already inspected this launch: not decoded again.
        writer.set(try JSONEncoder().encode(makeVideo()), for: track.id)
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: launch) == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 1)
        // A track first seen later in the launch is inspected.
        let late = TrackRecord(catalogID: "late", title: "Late", artistName: "Artist")
        context.insert(late)
        writer.set(try JSONEncoder().encode(makeVideo()), for: late.id)
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: launch) == 1)
        // The next launch inspects everything again.
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: VideoPlaybackScan(cache: reader)) == 1)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("Song-only copies preserve duplicates and video tracks cannot enter cached playback queues")
    func copiesAndCachedPlayback() throws {
        let video = try makeVideo()
        let song = try makeSong()
        #expect([video, song, song].filter(VideoTrackPolicy.isSong).map(\.id.rawValue) == ["song", "song"])
        #expect(AppleMusicPlaylistTrackLoader.videoMusicItemIDs(from: [video, song]) == ["video"])
        #expect(!PlaybackController.isQueueable(video))
        #expect(PlaybackController.isQueueable(song))
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

    /// The cleanup inspects each track's payload once per launch (PF-9), so a
    /// merge must not hand a keeper it has already inspected a video payload.
    @Test("A merge never copies a donor's video payload onto the keeper")
    func mergeCopiesOnlySongPayloads() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let videoData = try JSONEncoder().encode(makeVideo())
        let songData = try JSONEncoder().encode(makeSong())

        // A keeper with no payload takes a donor's song payload, not a video.
        let bare = TrackRecord(catalogID: "c.bare", title: "Song", artistName: "Artist")
        let videoDonor = TrackRecord(catalogID: "c.bare", title: "Song", artistName: "Artist", musicKitPlaybackData: videoData)
        let songDonor = TrackRecord(catalogID: "c.bare", title: "Song", artistName: "Artist", musicKitPlaybackData: songData)
        for track in [bare, videoDonor, songDonor] { context.insert(track) }
        TrackIdentityMergeService.absorb(videoDonor, into: bare)
        #expect(bare.musicKitPlaybackData == nil)
        TrackIdentityMergeService.absorb(songDonor, into: bare)
        #expect(bare.musicKitPlaybackData == songData)

        // A donor that becomes the representative copy brings its metadata,
        // but not a video payload: the keeper keeps its song.
        let keeper = TrackRecord(catalogID: "c.rep", libraryID: "i.b", title: "Keeper", artistName: "Artist",
                                 musicKitPlaybackData: songData)
        let representative = TrackRecord(catalogID: "c.rep", libraryID: "i.a", title: "Representative",
                                         artistName: "Artist", musicKitPlaybackData: videoData)
        for track in [keeper, representative] { context.insert(track) }
        TrackIdentityMergeService.absorb(representative, into: keeper)
        #expect(keeper.libraryID == "i.a" && keeper.title == "Representative")
        #expect(keeper.musicKitPlaybackData == songData)
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
