import Foundation
import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// A Mac cannot write Apple Music playlists, so it curates locally and an
/// iPhone or iPad brings Apple Music up to date (`PLAYLIST-008`, `SETUP-002`).
@MainActor
@Suite("Mac curation waits for an iPhone", .serialized)
struct MacLocalCurationTests {
    private struct Library {
        var context: ModelContext
        var bucket: PlaylistRecord
        var oneTruePlaylist: PlaylistRecord
    }

    private func library(_ container: ModelContainer, oneTruePlaylistID: String = "p.main") throws -> Library {
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let oneTruePlaylist = PlaylistRecord(musicPlaylistID: oneTruePlaylistID, name: "Overplay",
                                             role: .oneTruePlaylist, writePolicy: .managed)
        context.insert(oneTruePlaylist)
        try context.save()
        return Library(context: context, bucket: bucket, oneTruePlaylist: oneTruePlaylist)
    }

    private func item(_ libraryID: String, in playlist: PlaylistRecord, _ context: ModelContext) throws -> PlaylistItemRecord {
        let track = TrackRecord(libraryID: libraryID, title: libraryID, artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        context.insert(track); context.insert(item)
        try context.save()
        return item
    }

    private func librarySong(_ id: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs",
            "attributes": ["name": id, "artistName": "Artist", "albumName": "Album", "genreNames": []]
        ]))
    }

    private func entry(_ id: String) -> AppleMusicLibraryPlaylistResources.Entry {
        .init(id: id, type: "library-songs")
    }

    /// A service that records every Apple Music write.
    private func service(canWrite: Bool, cloud: @escaping () -> [String] = { [] },
                         written: @escaping (String) throws -> Void) -> PlaylistMutationService {
        var service = PlaylistMutationService()
        service.canWritePlaylists = { canWrite }
        service.remoteMembership.cloudEntries = { _ in cloud().map(entry) }
        service.librarySong = { try librarySong($0) }
        service.writeSong = { song, _, _ in try written(song.id.rawValue) }
        return service
    }

    // MARK: - Promotion on a Mac

    @Test("a Mac promotes locally, marks the song for an iPhone, and writes nothing")
    func macPromotesLocally() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let item = try item("i.song", in: library.bucket, library.context)
        var written: [String] = []

        let promoted = try await service(canWrite: false) { written.append($0) }.promote(item: item, in: library.context)

        #expect(written.isEmpty)
        #expect(promoted.playlistID == library.oneTruePlaylist.id)
        #expect(promoted.appleMusicAddPendingAt != nil)
        #expect(promoted.suppressedOTPMusicPlaylistIDs.isEmpty)
        let history = try library.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(history.contains { $0.eventType == .promoted && $0.remoteMutationStatus == .pending })
    }

    @Test("an iPhone promoting into a One True Playlist not yet in Apple Music records it locally")
    func promotionIntoUnmadePlaylistIsLocal() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container, oneTruePlaylistID: PlaylistRecord.unmadeOneTruePlaylistID())
        let item = try item("i.song", in: library.bucket, library.context)
        var written: [String] = []

        let promoted = try await service(canWrite: true) { written.append($0) }.promote(item: item, in: library.context)

        #expect(written.isEmpty)
        #expect(promoted.playlistID == library.oneTruePlaylist.id)
    }

    @Test("an iPhone still adds in Apple Music before moving, and marks nothing")
    func iPhonePromotionIsUnchanged() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let item = try item("i.song", in: library.bucket, library.context)
        var written: [String] = []

        let promoted = try await service(canWrite: true) { written.append($0) }.promote(item: item, in: library.context)

        #expect(written == ["i.song"])
        #expect(promoted.appleMusicAddPendingAt == nil)
    }

    @Test("retiring or moving a song back to the Inbox drops its pending add")
    func leavingClearsTheMark() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let retired = try item("i.retired", in: library.bucket, library.context)
        let returned = try item("i.returned", in: library.bucket, library.context)
        let mac = service(canWrite: false) { _ in }
        _ = try await mac.promote(item: retired, in: library.context)
        _ = try await mac.promote(item: returned, in: library.context)

        try TrackLocationService.retire(retired, playlist: library.oneTruePlaylist, reason: .manual, source: .user,
                                        message: "Retired manually", preserveForMerge: true, in: library.context)
        try TrackLocationService.moveToTriage(returned, explicitKeep: true, in: library.context)

        #expect(retired.appleMusicAddPendingAt == nil)
        #expect(returned.appleMusicAddPendingAt == nil)
        #expect(try PlaylistMutationService.itemsAwaitingAppleMusic(in: library.oneTruePlaylist, library.context).isEmpty)
    }

    @Test("a duplicate merge into the One True Playlist on a Mac commits and marks the keeper")
    func ensureRemoteMembershipOnMacCommitsLocally() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let item = try item("i.song", in: library.bucket, library.context)
        let track = try #require(try TrackRecordRepository.track(id: item.trackID, in: library.context))
        var written: [String] = []
        var beforeAddRan = false

        try await service(canWrite: false) { written.append($0) }.ensureRemoteMembership(
            track: track, playlist: library.oneTruePlaylist,
            isCurrent: { true }, beforeAdd: { beforeAddRan = true },
            commit: { TrackLocationService.moveToOTP(item, playlist: library.oneTruePlaylist, source: .user, in: library.context) },
            in: library.context
        )

        #expect(written.isEmpty)
        #expect(!beforeAddRan)
        #expect(item.playlistID == library.oneTruePlaylist.id)
        #expect(item.appleMusicAddPendingAt != nil)
    }

    // MARK: - The iPhone catches up

    @Test("after a sync an iPhone adds the marked songs iCloud lacks, and clears every mark")
    func iPhoneAddsMarkedSongs() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let missing = try item("i.missing", in: library.bucket, library.context)
        let present = try item("i.present", in: library.bucket, library.context)
        let mac = service(canWrite: false) { _ in }
        _ = try await mac.promote(item: missing, in: library.context)
        _ = try await mac.promote(item: present, in: library.context)
        var written: [String] = []

        let added = try await service(canWrite: true, cloud: { ["i.present"] }) { written.append($0) }
            .addSongsAwaitingAppleMusic(to: library.oneTruePlaylist, in: library.context)

        #expect(added == 1)
        #expect(written == ["i.missing"])
        #expect(missing.appleMusicAddPendingAt == nil && present.appleMusicAddPendingAt == nil)
        #expect(missing.playlistID == library.oneTruePlaylist.id)
    }

    @Test("a failed add keeps its mark for the next sync")
    func failedAddKeepsTheMark() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container)
        let item = try item("i.song", in: library.bucket, library.context)
        _ = try await service(canWrite: false) { _ in }.promote(item: item, in: library.context)

        let added = try await service(canWrite: true) { _ in throw PlaylistMutationError.musicItemMissing }
            .addSongsAwaitingAppleMusic(to: library.oneTruePlaylist, in: library.context)

        #expect(added == 0)
        #expect(item.appleMusicAddPendingAt != nil)
        #expect(item.playlistID == library.oneTruePlaylist.id)
    }

    @Test("a Mac never runs the catch-up, nor does a playlist not yet in Apple Music")
    func catchUpNeedsAWritableMadePlaylist() async throws {
        for (canWrite, playlistID) in [(false, "p.main"), (true, PlaylistRecord.unmadeOneTruePlaylistID())] {
            let container = try OverplayTestSupport.makeModelContainer()
            let library = try library(container, oneTruePlaylistID: playlistID)
            let item = try item("i.song", in: library.bucket, library.context)
            _ = try await service(canWrite: false) { _ in }.promote(item: item, in: library.context)
            var written: [String] = []

            let added = try await service(canWrite: canWrite) { written.append($0) }
                .addSongsAwaitingAppleMusic(to: library.oneTruePlaylist, in: library.context)

            #expect(added == 0)
            #expect(written.isEmpty)
            #expect(item.appleMusicAddPendingAt != nil)
        }
    }

    // MARK: - The One True Playlist before Apple Music has it

    @Test("sync leaves a One True Playlist not yet in Apple Music alone")
    func syncSkipsUnmadePlaylist() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container, oneTruePlaylistID: PlaylistRecord.unmadeOneTruePlaylistID())

        let summary = try await PlaylistSyncService().syncPlaylist(
            library.oneTruePlaylist, in: library.context, runIdentityMerge: false, runVideoCleanup: false
        )

        #expect(summary.skippedReason == "awaitsAppleMusicPlaylist")
        #expect(library.oneTruePlaylist.lastSyncError == nil)
        #expect(!library.oneTruePlaylist.hasRemoteSource)
    }

    @Test("choosing another One True Playlist ends the local one; its songs go to the Inbox unattributed")
    func choosingAnotherEndsTheLocalPlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container, oneTruePlaylistID: PlaylistRecord.unmadeOneTruePlaylistID())
        let item = try item("i.song", in: library.oneTruePlaylist, library.context)

        try PlaylistRepository.setOneTruePlaylist(AppleMusicPlaylist(id: "p.real", name: "Real"), in: library.context)

        #expect(!library.oneTruePlaylist.isActive)
        #expect(library.oneTruePlaylist.role == .oneTruePlaylist)
        #expect(item.playlistID == library.bucket.id)
        #expect(item.sourceMusicPlaylistIDs.isEmpty)
    }

    @Test("making the Apple Music playlist from the local one adds every active song and clears the marks")
    func rebuildMakesTheLocalPlaylist() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let library = try library(container, oneTruePlaylistID: PlaylistRecord.unmadeOneTruePlaylistID())
        let copied = try item("i.copied", in: library.oneTruePlaylist, library.context)
        let promoted = try item("i.promoted", in: library.bucket, library.context)
        _ = try await service(canWrite: false) { _ in }.promote(item: promoted, in: library.context)
        var loadedFrom: [String] = []
        var created: [String] = []

        var rebuild = OneTruePlaylistRebuildService()
        rebuild.canCreatePlaylists = { true }
        rebuild.addableTracks = { records, playlistID in
            loadedFrom.append(playlistID)
            return records.reduce(into: [:]) { $0[$1.id] = try? .song(librarySong($1.libraryID ?? "")) }
        }
        rebuild.createPlaylist = { name, items in
            created = items.map(\.id.rawValue)
            return try JSONDecoder().decode(Playlist.self, from: JSONSerialization.data(withJSONObject: [
                "id": "p.made", "type": "library-playlists", "attributes": ["name": name, "canEdit": true]
            ]))
        }
        rebuild.durableID = { $0.id.rawValue }
        rebuild.sync = { _, _ in }

        let result = try await rebuild.rebuild(in: library.context)

        #expect(result.addedCount == 2)
        #expect(Set(created) == ["i.copied", "i.promoted"])
        #expect(library.oneTruePlaylist.musicPlaylistID == "p.made")
        #expect(!library.oneTruePlaylist.awaitsAppleMusicPlaylist)
        #expect(promoted.appleMusicAddPendingAt == nil)
        #expect(copied.playlistID == library.oneTruePlaylist.id)
    }
}

/// `SETUP-002` with the Mac's local One True Playlist.
@MainActor
@Suite("One True Playlist a Mac made locally", .serialized)
struct PendingLocalOneTruePlaylistTests {
    private func library() throws -> (ModelContainer, OverplaySettings) {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings()
        context.insert(settings)
        _ = try PlaylistRepository.triageBucket(in: context)
        try context.save()
        return (container, settings)
    }

    private func service(made: @escaping (PlaylistRecord) -> Void) -> PendingOneTruePlaylistService {
        var service = PendingOneTruePlaylistService()
        service.canCreatePlaylists = { true }
        service.createManagedOneTruePlaylist = { _, _, _ in
            Issue.record("made a second One True Playlist")
            throw PlaylistSyncError.playlistNotFound
        }
        service.makeFromLocalOneTruePlaylist = { context in
            let local = try #require(try PlaylistRepository.oneTruePlaylist(in: context))
            local.musicPlaylistID = "p.made"
            try context.save()
            made(local)
        }
        return service
    }

    @Test("an iPhone makes the Mac's local playlist in Apple Music, keeps the same record and selects it")
    func iPhoneMakesTheLocalPlaylist() async throws {
        let (container, settings) = try library()
        let context = container.mainContext
        let local = PlaylistRecord(musicPlaylistID: PlaylistRecord.unmadeOneTruePlaylistID(), name: "Overplay",
                                   role: .oneTruePlaylist, writePolicy: .managed)
        context.insert(local)
        try context.save()
        try PendingOneTruePlaylistService.request(copying: AppleMusicPlaylist(id: "p.favourites", name: "Favourites"),
                                                  local: local, in: context)
        var made: [UUID] = []

        let playlist = await service { made.append($0.id) }.fulfilIfNeeded(in: context)

        #expect(playlist?.id == local.id)
        #expect(made == [local.id])
        #expect(settings.selectedPlaylistID == "p.made")
        #expect(settings.pendingOneTruePlaylistRequestedAt == nil && settings.pendingOneTruePlaylistLocalID == nil)
        #expect(local.isActive && local.role == .oneTruePlaylist)
    }

    @Test("an iPhone waits until iCloud delivers the Mac's local playlist")
    func iPhoneWaitsForTheLocalPlaylist() async throws {
        let (container, settings) = try library()
        let context = container.mainContext
        try PendingOneTruePlaylistService.request(copying: nil, in: context)
        settings.pendingOneTruePlaylistLocalID = PlaylistRecord.unmadeOneTruePlaylistID()
        try context.save()
        var made = 0

        let playlist = await service { _ in made += 1 }.fulfilIfNeeded(in: context)

        #expect(playlist == nil)
        #expect(made == 0)
        #expect(settings.pendingOneTruePlaylistRequestedAt != nil)
        #expect(settings.selectedPlaylistID == nil)
    }
}
