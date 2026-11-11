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

        #expect(try await VideoTrackCleanupService.removeVideos(knownVideoIDs: ["video", "i.video"], in: context) == 1)
        #expect(try PlaylistItemRepository.allItems(in: context).map(\.trackID) == [alsoKept])
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
    }

    @Test("Remote video identities remove legacy rows by their own IDs, with or without playback data")
    func cleanupUsingRemoteEvidence() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let video = TrackRecord(libraryID: "i.video", title: "Video", artistName: "Artist")
        video.confirmedAliases = [.catalog("video")]
        let withPayload = TrackRecord(catalogID: "c.video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        context.insert(video)
        context.insert(withPayload)
        #expect(try await VideoTrackCleanupService.removeVideos(knownVideoIDs: ["i.video", "c.video"],
            inspectPlaybackData: false, in: context) == 2)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    /// A confirmed duplicate merge keeps the donor video's IDs as the song
    /// keeper's aliases. A later sync naming that video must not delete the
    /// song (data loss); a row that is the video itself still goes.
    @Test("A song that absorbed a video by a duplicate merge survives that video's remote evidence")
    func songKeeperHoldingVideoAliasSurvives() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        // No payload on this device, so only the ID rule can keep it.
        let song = TrackRecord(id: ids[0], catalogID: "song", libraryID: "i.song", title: "Song", artistName: "Artist")
        let donor = TrackRecord(id: ids[1], catalogID: "video", libraryID: "i.video", title: "Song", artistName: "Artist")
        for track in [song, donor] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .trackAdded, source: .user))
        }
        try context.save()
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == song.id)
        #expect(Set(song.identityAliases).isSuperset(of: ["video", "i.video"]))
        // Another device's legacy row of the video itself.
        let video = TrackRecord(catalogID: "video", title: "Video", artistName: "Artist")
        context.insert(video)
        context.insert(PlaylistItemRecord(playlistID: UUID(), trackID: video.id))
        try context.save()

        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .triageSource)
        context.insert(playlist)
        let adapter = VideoEvidenceSource(result: PlaylistSourceFetchResult(snapshots: [], skippedCount: 1,
            skippedReason: "remoteUnchanged", didFetchTracks: false, videoMusicItemIDs: ["video", "i.video"]))
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        _ = try await service.syncPlaylist(playlist, in: context, runIdentityMerge: false, skipWhenRemoteUnchanged: true)

        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [song.id])
        let items = try PlaylistItemRepository.allItems(in: reloaded)
        #expect(items.map(\.trackID) == [song.id])
        #expect(items.first?.playlistID == bucket.id)
        #expect(!(try reloaded.fetch(FetchDescriptor<HistoryEvent>()).isEmpty))
        #expect(try reloaded.fetch(FetchDescriptor<HistoryEvent>()).allSatisfy { $0.trackID == song.id })
    }

    /// A merge on a device that does not know the donor is a video (no
    /// payload) gives a keeper with no catalog ID the donor's, so a song can
    /// hold a video's ID as its own. Its stored song payload keeps it.
    @Test("A song keeper given a video's catalog ID by a merge survives that ID's remote evidence")
    func songKeeperWithInheritedVideoIDSurvives() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let song = TrackRecord(id: ids[0], libraryID: "i.song", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeSong()))
        let donor = TrackRecord(id: ids[1], catalogID: "video", title: "Song", artistName: "Artist")
        for track in [song, donor] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id))
        }
        try context.save()
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == song.id)
        #expect(song.catalogID == "video")

        #expect(try await VideoTrackCleanupService.removeVideos(knownVideoIDs: ["video"], inspectPlaybackData: false, in: context) == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).map(\.id) == [song.id])
        #expect(try PlaylistItemRepository.allItems(in: context).map(\.trackID) == [song.id])
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

        // A known video never becomes the representative copy: the keeper
        // keeps its own library ID, metadata and song payload.
        let keeper = TrackRecord(catalogID: "c.rep", libraryID: "i.b", title: "Keeper", artistName: "Artist",
                                 musicKitPlaybackData: songData)
        let representative = TrackRecord(catalogID: "c.rep", libraryID: "i.a", title: "Representative",
                                         artistName: "Artist", musicKitPlaybackData: videoData)
        for track in [keeper, representative] { context.insert(track) }
        TrackIdentityMergeService.absorb(representative, into: keeper)
        #expect(keeper.libraryID == "i.b" && keeper.title == "Keeper")
        #expect(keeper.musicKitPlaybackData == songData)
        #expect(keeper.confirmedAliases.contains(.library("i.a", scope: representative.libraryScope)))
    }

    /// Video cleanup trusts a track's own IDs, so a known video donor's IDs
    /// become aliases only. A song donor still fills a missing ID.
    @Test("A known video donor never gives the keeper its own catalog or library ID")
    func videoDonorFillsAliasesOnly() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let videoData = try JSONEncoder().encode(makeVideo())

        let libraryOnly = TrackRecord(libraryID: "i.song", title: "Song", artistName: "Artist")
        let catalogVideo = TrackRecord(catalogID: "video", title: "Song", artistName: "Artist", musicKitPlaybackData: videoData)
        let catalogOnly = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        let libraryVideo = TrackRecord(libraryID: "i.video", title: "Song", artistName: "Artist", musicKitPlaybackData: videoData)
        // A documented video sharing the keeper's library ID does not set its catalog ID.
        let sharedLibrary = TrackRecord(libraryID: "i.shared", title: "Song", artistName: "Artist")
        let documentedVideo = TrackRecord(catalogID: "doc.video", libraryID: "i.shared", title: "Song", artistName: "Artist",
                                          musicKitPlaybackData: videoData)
        documentedVideo.hasDocumentedIdentity = true
        for track in [libraryOnly, catalogVideo, catalogOnly, libraryVideo, sharedLibrary, documentedVideo] { context.insert(track) }

        TrackIdentityMergeService.absorb(catalogVideo, into: libraryOnly, confirmed: true)
        #expect(libraryOnly.catalogID == nil && libraryOnly.libraryID == "i.song")
        #expect(libraryOnly.identityAliases.contains("video"))
        TrackIdentityMergeService.absorb(libraryVideo, into: catalogOnly, confirmed: true)
        #expect(catalogOnly.libraryID == nil && catalogOnly.catalogID == "song")
        #expect(catalogOnly.identityAliases.contains("i.video"))
        TrackIdentityMergeService.absorb(documentedVideo, into: sharedLibrary)
        #expect(sharedLibrary.catalogID == nil && sharedLibrary.libraryID == "i.shared")

        // Parity: a song donor fills the missing IDs as before.
        let songDonor = TrackRecord(catalogID: "c.song", libraryID: "i.other", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeSong()))
        let bare = TrackRecord(title: "Song", artistName: "Artist")
        for track in [songDonor, bare] { context.insert(track) }
        TrackIdentityMergeService.absorb(songDonor, into: bare, confirmed: true)
        #expect(bare.catalogID == "c.song" && bare.libraryID == "i.other")
    }

    /// Gap 1 of #134: a library-only song that absorbed a video used to take
    /// the video's catalog ID as its own; on a device with no song payload a
    /// sync naming that video then deleted the song and its memberships.
    @Test("A library-only song that merged a known video survives that video's catalog ID without playback data")
    func libraryOnlySongMergingKnownVideoSurvivesSync() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        // The song is first by UUID, so it is the keeper either way, and has no payload.
        let song = TrackRecord(id: ids[0], libraryID: "i.song", title: "Song", artistName: "Artist")
        let video = TrackRecord(id: ids[1], catalogID: "video", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        for track in [song, video] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .trackAdded, source: .user))
        }
        try context.save()
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == song.id)
        #expect(song.catalogID == nil)
        #expect(song.identityAliases.contains("video"))

        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .triageSource)
        context.insert(playlist)
        let adapter = VideoEvidenceSource(result: PlaylistSourceFetchResult(snapshots: [], skippedCount: 1,
            skippedReason: "remoteUnchanged", didFetchTracks: false, videoMusicItemIDs: ["video"]))
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        _ = try await service.syncPlaylist(playlist, in: context, runIdentityMerge: false, skipWhenRemoteUnchanged: true)

        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [song.id])
        let items = try PlaylistItemRepository.allItems(in: reloaded)
        #expect(items.map(\.trackID) == [song.id])
        #expect(items.first?.playlistID == bucket.id)
        let events = try reloaded.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!events.isEmpty && events.allSatisfy { $0.trackID == song.id })
    }

    /// Gap 2 of #134: the keeper is the first candidate in the destination,
    /// then by UUID, so a legacy video row could be kept. The full scan then
    /// deleted it, and with it the merged song.
    @Test("A duplicate merge keeps the song over a known video, so cleanup leaves the song")
    func duplicateMergeNeverKeepsKnownVideo() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        // The video is first by UUID and in the same collection: it was the keeper.
        let video = TrackRecord(id: ids[0], catalogID: "video", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        let song = TrackRecord(id: ids[1], catalogID: "song", title: "Song", artistName: "Artist")
        for track in [video, song] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .trackAdded, source: .user))
        }
        try context.save()
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == song.id)
        #expect(song.catalogID == "song")

        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: VideoPlaybackScan(cache: .shared)) == 0)
        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [song.id])
        #expect(try PlaylistItemRepository.allItems(in: reloaded).map(\.trackID) == [song.id])
        let events = try reloaded.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!events.isEmpty && events.allSatisfy { $0.trackID == song.id })
    }

    /// The same rule for the automatic identity merge, whose keeper is
    /// otherwise the oldest record: a legacy video row joined to a song by
    /// an alias is never kept over it.
    @Test("An identity merge keeps the song over an older known video, so cleanup leaves the song")
    func identityMergeNeverKeepsKnownVideo() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let video = TrackRecord(catalogID: "video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()), createdAt: Date(timeIntervalSince1970: 100))
        let song = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist", createdAt: Date(timeIntervalSince1970: 200))
        song.confirmedAliases = [.catalog("video")]
        context.insert(video)
        context.insert(song)
        context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: song.id, playthroughCount: 2))
        try context.save()

        let summary = try await TrackIdentityMergeService.mergeDuplicates(in: context)
        #expect(summary.localTrackIDMapping == [video.id.uuidString: song.id.uuidString])
        #expect(song.catalogID == "song")
        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: VideoPlaybackScan(cache: .shared)) == 0)
        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [song.id])
        #expect(try PlaylistItemRepository.allItems(in: reloaded).map(\.trackID) == [song.id])
    }

    /// Review of #134: a video row this device does not know is a video can
    /// be the merge keeper, holding the video's IDs as its own. A device
    /// without the song payload the merge copied must not delete it on a
    /// sync's video IDs, or the merged song's rows go with it everywhere.
    @Test("An unrecognised video kept by a merge survives the video's remote IDs, with the merged song's rows")
    func unrecognisedVideoKeeperSurvivesRemoteEvidence() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        // The video row is first by UUID and has no payload here, so it is kept.
        let video = TrackRecord(id: ids[0], catalogID: "video", libraryID: "i.video", title: "Song", artistName: "Artist")
        let song = TrackRecord(id: ids[1], catalogID: "song", libraryID: "i.song", title: "Song", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeSong()))
        for track in [video, song] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .trackAdded, source: .user))
        }
        try context.save()
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == video.id)
        #expect(video.catalogID == "video" && video.libraryID == "i.video")
        #expect(video.absorbedTrackIDs == [song.id.uuidString])
        // Another device: the copied song payload is not here.
        video.musicKitPlaybackData = nil

        let playlist = PlaylistRecord(musicPlaylistID: "source", name: "Source", role: .triageSource)
        context.insert(playlist)
        let adapter = VideoEvidenceSource(result: PlaylistSourceFetchResult(snapshots: [], skippedCount: 1,
            skippedReason: "remoteUnchanged", didFetchTracks: false, videoMusicItemIDs: ["video", "i.video"]))
        let service = PlaylistSyncService(sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: adapter]))
        _ = try await service.syncPlaylist(playlist, in: context, runIdentityMerge: false, skipWhenRemoteUnchanged: true)

        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [video.id])
        let items = try PlaylistItemRepository.allItems(in: reloaded)
        #expect(items.map(\.trackID) == [video.id])
        #expect(items.first?.playlistID == bucket.id)
        let events = try reloaded.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!events.isEmpty && events.allSatisfy { $0.trackID == video.id })
    }

    /// The playback-data scan on a device that does know the keeper is a
    /// video must not delete it either: the merged song's rows are its rows.
    @Test("The playback-data scan keeps a video row that absorbed a song by a merge")
    func playbackScanKeepsVideoKeeperThatAbsorbedSong() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let video = TrackRecord(id: ids[0], catalogID: "video", title: "Song", artistName: "Artist")
        let song = TrackRecord(id: ids[1], catalogID: "song", title: "Song", artistName: "Artist")
        for track in [video, song] {
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2))
            context.insert(HistoryEvent(trackID: track.id, eventType: .trackAdded, source: .user))
        }
        try context.save()
        // Merged where the video was unknown; this device has its video payload.
        let merged = try DuplicateTrackService.merge(try DuplicateTrackService.candidates(in: context), destination: nil, in: context)
        #expect(merged.trackID == video.id)
        video.musicKitPlaybackData = try JSONEncoder().encode(makeVideo())
        defer { video.musicKitPlaybackData = nil }
        // A video row that absorbed nothing still goes.
        let plain = TrackRecord(catalogID: "other-video", title: "Video", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        context.insert(plain)
        try context.save()

        #expect(try await VideoTrackCleanupService.removeVideos(in: context, scan: VideoPlaybackScan(cache: .shared)) == 1)
        let reloaded = ModelContext(container)
        #expect(try TrackRecordRepository.allTracks(in: reloaded).map(\.id) == [video.id])
        #expect(try PlaylistItemRepository.allItems(in: reloaded).map(\.trackID) == [video.id])
        let events = try reloaded.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!events.isEmpty && events.allSatisfy { $0.trackID == video.id })
    }

    /// Review of #134: the merge keeps the song over a known video row that
    /// is already in the One True Playlist, so the remote add must follow
    /// the keeper rather than skip because some selected row is there.
    @Test("A merge into the One True Playlist that keeps a song over a known video there adds the song to Apple Music")
    func otpMergeKeepingSongOverKnownVideoAddsSong() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let context = fixture.context
        let video = TrackRecord(catalogID: "video", title: "Dup", artistName: "Artist",
            musicKitPlaybackData: try JSONEncoder().encode(makeVideo()))
        defer { video.musicKitPlaybackData = nil }
        let song = TrackRecord(catalogID: "song", libraryID: "i.song", title: "Dup", artistName: "Artist")
        video.isrc = "SAME-RECORDING"
        song.isrc = "SAME-RECORDING"
        context.insert(video)
        context.insert(song)
        context.insert(PlaylistItemRecord(playlistID: fixture.playlist.id, trackID: video.id))
        let songItem = PlaylistItemRecord(playlistID: try PlaylistRepository.triageBucket(in: context).id, trackID: song.id)
        context.insert(songItem)
        try context.save()
        let added = AddedTracks()
        var mutations = PlaylistMutationService(addRemotely: { track, playlist, _ in
            added.entries.append("\(playlist.musicPlaylistID):\(track.id)")
        })
        mutations.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.playlistMutations = mutations
        fixture.controller.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.remoteMembership.canEditPlaylists = { false }
        let selected = try DuplicateTrackService.candidates(in: context).filter { $0.isrc == "SAME-RECORDING" }
        try #require(selected.count == 2)

        _ = try await fixture.controller.mergeDuplicateTracks(selected, destination: .otp, context: context)

        #expect(added.entries == ["\(fixture.playlist.musicPlaylistID):\(song.id)"])
        #expect(try TrackRecordRepository.track(id: video.id, in: context) == nil)
        #expect(songItem.playlistID == fixture.playlist.id && songItem.evictedAt == nil)
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

@MainActor
private final class AddedTracks {
    var entries: [String] = []
}
