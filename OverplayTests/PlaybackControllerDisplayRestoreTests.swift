import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback controller display restore")
struct PlaybackControllerDisplayRestoreTests {
    @Test("evaluation outcome matches currently displayed item")
    func evaluationOutcomeMatchesCurrentlyDisplayedItem() {
        let controller = PlaybackController()
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main")
        let track = TrackRecord(catalogID: "music-1", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        controller.currentPlaylistItem = item
        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "Track", artistName: "Artist")

        let outcome = PlaybackSessionEvaluationService.EvaluationOutcome(
            session: TrackPlaySession(
                trackID: "music-1",
                localTrackID: track.id.uuidString,
                sessionStartDate: Date(timeIntervalSince1970: 100),
                lastObservedPlaybackTime: 12,
                durationSeconds: 120,
                hasEvaluated: true
            ),
            playlist: playlist,
            item: item,
            shouldSyncPlaybackMetadata: true
        )

        #expect(controller.evaluationOutcomeMatchesDisplayedPlayback(outcome))
    }

    @Test("stale evaluation outcome does not match newly displayed item")
    func staleEvaluationOutcomeDoesNotMatchNewlyDisplayedItem() {
        let controller = PlaybackController()
        let playlist = PlaylistRecord(musicPlaylistID: "playlist-1", name: "Main")
        let previousTrack = TrackRecord(catalogID: "previous", title: "Previous", artistName: "Artist")
        let newTrack = TrackRecord(catalogID: "new", title: "New", artistName: "Artist")
        let previousItem = PlaylistItemRecord(playlistID: playlist.id, trackID: previousTrack.id)
        let newItem = PlaylistItemRecord(playlistID: playlist.id, trackID: newTrack.id)
        controller.currentPlaylistItem = newItem
        controller.currentTrack = CurrentPlaybackTrack(id: "new", title: "New", artistName: "Artist")

        let staleOutcome = PlaybackSessionEvaluationService.EvaluationOutcome(
            session: TrackPlaySession(
                trackID: "previous",
                localTrackID: previousTrack.id.uuidString,
                sessionStartDate: Date(timeIntervalSince1970: 100),
                lastObservedPlaybackTime: 12,
                durationSeconds: 120,
                hasEvaluated: true
            ),
            playlist: playlist,
            item: previousItem,
            shouldSyncPlaybackMetadata: true
        )

        #expect(!controller.evaluationOutcomeMatchesDisplayedPlayback(staleOutcome))
    }

    @Test("stale evaluation refreshes active playlist snapshot without replacing display")
    func staleEvaluationRefreshesActivePlaylistSnapshotWithoutReplacingDisplay() throws {
        let fixture = try makeTwoTrackFixture()
        let controller = PlaybackController()
        controller.currentPlaylistID = fixture.playlist.musicPlaylistID
        controller.currentPlaylistItem = fixture.nextItem
        controller.currentTrack = CurrentPlaybackTrack(
            id: "next-library",
            title: fixture.nextTrack.title,
            artistName: fixture.nextTrack.artistName,
            durationSeconds: 180
        )
        controller.activePlaylistSnapshot = ActivePlaylistSnapshot(
            playlist: fixture.playlist,
            items: [fixture.previousItem, fixture.nextItem],
            tracks: [fixture.previousTrack, fixture.nextTrack],
            playbackOrderState: PlaybackOrderState(
                playerID: controller.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID
            ),
            currentPlaylistItemID: fixture.nextItem.id
        )
        fixture.previousItem.skipCount = 1
        try fixture.context.save()

        let staleOutcome = PlaybackSessionEvaluationService.EvaluationOutcome(
            session: TrackPlaySession(
                trackID: "previous-library",
                localTrackID: fixture.previousTrack.id.uuidString,
                sessionStartDate: Date(timeIntervalSince1970: 100),
                lastObservedPlaybackTime: 12,
                durationSeconds: 120,
                hasEvaluated: true
            ),
            playlist: fixture.playlist,
            item: fixture.previousItem,
            shouldSyncPlaybackMetadata: true
        )

        controller.applyEvaluationOutcome(staleOutcome, context: fixture.context)

        #expect(controller.currentPlaylistItem?.id == fixture.nextItem.id)
        #expect(controller.currentTrack?.id == "next-library")
        #expect(controller.activePlaylistSnapshot?.rows.first { $0.id == fixture.previousItem.id }?.skipCount == 1)
        #expect(controller.activePlaylistSnapshot?.rows.first { $0.id == fixture.previousItem.id }?.isCurrent == false)
        #expect(controller.activePlaylistSnapshot?.rows.first { $0.id == fixture.nextItem.id }?.isCurrent == true)
    }

    @Test("playlist row playback evaluates outgoing track before target track")
    func playlistRowPlaybackEvaluatesOutgoingTrackBeforeTargetTrack() async throws {
        let fixture = try makeTwoTrackFixture()
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        controller.currentPlaylistID = fixture.playlist.musicPlaylistID
        controller.currentPlaylistItem = fixture.previousItem
        controller.currentTrack = CurrentPlaybackTrack(
            id: "previous-library",
            title: fixture.previousTrack.title,
            artistName: fixture.previousTrack.artistName,
            durationSeconds: 180
        )
        controller.elapsedSeconds = 15
        controller.durationSeconds = 180

        await controller.evaluateOutgoingSessionBeforePlaybackReplacement(
            settings: settings,
            context: fixture.context,
            targetPlaylistID: fixture.playlist.musicPlaylistID,
            targetLocalTrackID: fixture.nextTrack.id.uuidString
        )

        #expect(fixture.previousItem.skipCount == 1)
        #expect(fixture.nextItem.skipCount == 0)
    }

    @Test("playlist row playback does not evaluate when target is current track")
    func playlistRowPlaybackDoesNotEvaluateWhenTargetIsCurrentTrack() async throws {
        let fixture = try makeTwoTrackFixture()
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        controller.currentPlaylistID = fixture.playlist.musicPlaylistID
        controller.currentPlaylistItem = fixture.previousItem
        controller.currentTrack = CurrentPlaybackTrack(
            id: "previous-library",
            title: fixture.previousTrack.title,
            artistName: fixture.previousTrack.artistName,
            durationSeconds: 180
        )
        controller.elapsedSeconds = 15
        controller.durationSeconds = 180

        await controller.evaluateOutgoingSessionBeforePlaybackReplacement(
            settings: settings,
            context: fixture.context,
            targetPlaylistID: fixture.playlist.musicPlaylistID,
            targetLocalTrackID: fixture.previousTrack.id.uuidString
        )

        #expect(fixture.previousItem.skipCount == 0)
        #expect(fixture.nextItem.skipCount == 0)
    }

    @Test("playlist row playback in another playlist evaluates outgoing current playlist item")
    func playlistRowPlaybackInAnotherPlaylistEvaluatesOutgoingCurrentPlaylistItem() async throws {
        let fixture = try makeTwoPlaylistFixture()
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        controller.currentPlaylistID = fixture.currentPlaylist.musicPlaylistID
        controller.currentPlaylistItem = fixture.currentItem
        controller.currentTrack = CurrentPlaybackTrack(
            id: "current-library",
            title: fixture.currentTrack.title,
            artistName: fixture.currentTrack.artistName,
            durationSeconds: 180
        )
        controller.elapsedSeconds = 15
        controller.durationSeconds = 180

        await controller.evaluateOutgoingSessionBeforePlaybackReplacement(
            settings: settings,
            context: fixture.context,
            targetPlaylistID: fixture.targetPlaylist.musicPlaylistID,
            targetLocalTrackID: fixture.targetTrack.id.uuidString
        )

        #expect(fixture.currentItem.skipCount == 1)
        #expect(fixture.targetItem.skipCount == 0)
    }

    @Test("stored order reconcile rebuilds the active snapshot only when the order changes")
    func storedOrderReconcileRebuildsTheActiveSnapshotOnlyWhenTheOrderChanges() throws {
        let fixture = try makeTwoTrackFixture()
        let controller = PlaybackController(playerID: "test-\(UUID().uuidString)")
        defer {
            PlaybackOrderStore.clear(
                playerID: controller.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID,
                flushImmediately: true
            )
        }
        controller.currentPlaylistID = fixture.playlist.musicPlaylistID

        controller.reconcileStoredOrder(for: fixture.playlist, context: fixture.context)

        let orderState = controller.playbackOrderState(for: fixture.playlist.musicPlaylistID)
        #expect(orderState.orderedTrackIDs.count == 2)
        #expect(controller.activePlaylistSnapshot != nil)

        controller.activePlaylistSnapshot = nil
        controller.reconcileStoredOrder(for: fixture.playlist, context: fixture.context)

        #expect(controller.activePlaylistSnapshot == nil)
    }

    @Test("display restore state builds a non-countable session")
    func displayRestoreStateBuildsANonCountableSession() throws {
        let fixture = try makeTwoPlaylistFixture()
        let state = LocalPlaybackState(
            playlistID: fixture.currentPlaylist.musicPlaylistID,
            musicItemID: "current-library",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: fixture.currentTrack.id.uuidString
        )

        let restored = try PlaybackRestorationService.displayRestoreState(from: state, in: fixture.context)

        #expect(restored?.activeSession.hasEvaluated == true)
        #expect(restored?.activeSession.lastObservedAt == Date(timeIntervalSince1970: 100))
        #expect(restored?.playlistItem?.id == fixture.currentItem.id)
    }

    @Test("display-restored session never counts when playback moves elsewhere")
    func displayRestoredSessionNeverCountsWhenPlaybackMovesElsewhere() async throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let fixture = try makeTwoPlaylistFixture()
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: fixture.currentPlaylist.musicPlaylistID,
            musicItemID: "current-library",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: fixture.currentTrack.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: fixture.context)
        #expect(controller.currentPlaylistItem?.id == fixture.currentItem.id)

        await controller.evaluateOutgoingSessionBeforePlaybackReplacement(
            settings: settings,
            context: fixture.context,
            targetPlaylistID: fixture.targetPlaylist.musicPlaylistID,
            targetLocalTrackID: fixture.targetTrack.id.uuidString
        )

        let history = try fixture.context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(fixture.currentItem.skipCount == 0)
        #expect(fixture.currentItem.playthroughCount == 0)
        #expect(history.isEmpty)
    }

    @Test("restores mini player display from local database state")
    func restoresMiniPlayerDisplayFromLocalDatabaseState() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            albumTitle: "Ready Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 1
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)

        #expect(controller.currentPlaylistID == playlist.musicPlaylistID)
        #expect(controller.currentPlaylistItem?.id == item.id)
        #expect(controller.currentTrack?.title == "Ready Track")
        #expect(controller.currentTrack?.artistName == "Ready Artist")
        #expect(controller.currentTrack?.artworkURLTemplate == "https://example.com/artwork.jpg")
        #expect(controller.elapsedSeconds == 42)
        #expect(controller.durationSeconds == 180)
        #expect(controller.displayedSkipCount == 1)
        #expect(!controller.isPlaying)
        #expect(!controller.canControlPlayback)
        #expect(controller.playbackItemMetadataVersion > 0)
        #expect(controller.activePlaylistSnapshot?.musicPlaylistID == playlist.musicPlaylistID)
        #expect(controller.activePlaylistSnapshot?.rows.first?.id == item.id)
        #expect(controller.activePlaylistSnapshot?.rows.first?.skipCount == 1)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isCurrent == true)
    }

    private func makeTwoTrackFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        playlist: PlaylistRecord,
        previousTrack: TrackRecord,
        previousItem: PlaylistItemRecord,
        nextTrack: TrackRecord,
        nextItem: PlaylistItemRecord
    ) {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let previousTrack = TrackRecord(
            catalogID: "previous-catalog",
            libraryID: "previous-library",
            title: "Previous Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let nextTrack = TrackRecord(
            catalogID: "next-catalog",
            libraryID: "next-library",
            title: "Next Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let previousItem = PlaylistItemRecord(playlistID: playlist.id, trackID: previousTrack.id, skipCount: 0)
        let nextItem = PlaylistItemRecord(playlistID: playlist.id, trackID: nextTrack.id, skipCount: 0)
        context.insert(playlist)
        context.insert(previousTrack)
        context.insert(nextTrack)
        context.insert(previousItem)
        context.insert(nextItem)
        return (container, context, playlist, previousTrack, previousItem, nextTrack, nextItem)
    }

    private func makeTwoPlaylistFixture() throws -> (
        container: ModelContainer,
        context: ModelContext,
        currentPlaylist: PlaylistRecord,
        currentTrack: TrackRecord,
        currentItem: PlaylistItemRecord,
        targetPlaylist: PlaylistRecord,
        targetTrack: TrackRecord,
        targetItem: PlaylistItemRecord
    ) {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let currentPlaylist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Current",
            role: .oneTruePlaylist
        )
        let targetPlaylist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Target",
            role: .triage
        )
        let currentTrack = TrackRecord(
            catalogID: "current-catalog",
            libraryID: "current-library",
            title: "Current Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let targetTrack = TrackRecord(
            catalogID: "target-catalog",
            libraryID: "target-library",
            title: "Target Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let currentItem = PlaylistItemRecord(playlistID: currentPlaylist.id, trackID: currentTrack.id, skipCount: 0)
        let targetItem = PlaylistItemRecord(playlistID: targetPlaylist.id, trackID: targetTrack.id, skipCount: 0)
        context.insert(currentPlaylist)
        context.insert(targetPlaylist)
        context.insert(currentTrack)
        context.insert(targetTrack)
        context.insert(currentItem)
        context.insert(targetItem)
        return (container, context, currentPlaylist, currentTrack, currentItem, targetPlaylist, targetTrack, targetItem)
    }

    @Test("keep current refreshes displayed skip count")
    func keepCurrentRefreshesDisplayedSkipCount() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let settings = OverplaySettings(protectKeptTracks: false)
        context.insert(settings)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 2
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)
        #expect(controller.displayedSkipCount == 2)
        #expect(controller.activePlaylistSnapshot?.rows.first?.skipCount == 2)

        controller.keepCurrent(settings: settings, context: context)

        #expect(item.skipCount == 0)
        #expect(controller.displayedSkipCount == 0)
        #expect(controller.activePlaylistSnapshot?.rows.first?.skipCount == 0)
    }

    @Test("reset current skip count refreshes displayed metadata")
    func resetCurrentSkipCountRefreshesDisplayedMetadata() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 3
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedSkipCount == 3)

        controller.resetCurrentSkipCount(context: context, message: "Skip count reset in CarPlay")

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 0)
        #expect(controller.displayedSkipCount == 0)
        #expect(controller.activePlaylistSnapshot?.rows.first?.skipCount == 0)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(history.first?.message == "Skip count reset in CarPlay")
    }

    @Test("protect current track refreshes displayed metadata")
    func protectCurrentTrackRefreshesDisplayedMetadata() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 3,
            protected: false
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(!controller.displayedIsProtected)

        controller.protectCurrentTrack(context: context, message: "Protected in CarPlay")

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.protected)
        #expect(controller.displayedIsProtected)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isProtected == true)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(history.first?.message == "Protected in CarPlay")

        let protectedMetadataVersion = controller.playbackItemMetadataVersion
        controller.toggleCurrentKeep(
            context: context,
            enabledMessage: "Keep turned on in CarPlay",
            disabledMessage: "Keep turned off in CarPlay"
        )

        let updatedHistory = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!item.protected)
        #expect(!controller.displayedIsProtected)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isProtected == false)
        #expect(controller.playbackItemMetadataVersion > protectedMetadataVersion)
        #expect(updatedHistory.compactMap(\.message).contains("Keep turned off in CarPlay"))
    }

    @Test("reset all local stats refreshes displayed metadata")
    func resetAllLocalStatsRefreshesDisplayedMetadata() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 4,
            playthroughCount: 2,
            evictedAt: Date(timeIntervalSince1970: 200),
            protected: true
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedSkipCount == 4)
        #expect(controller.displayedPlaythroughCount == 2)
        #expect(controller.displayedIsProtected)
        #expect(controller.displayedIsEvicted)

        try controller.resetAllLocalStats(context: context)

        #expect(item.skipCount == 0)
        #expect(item.playthroughCount == 0)
        #expect(item.evictedAt == nil)
        #expect(!item.protected)
        #expect(controller.displayedSkipCount == 0)
        #expect(controller.displayedPlaythroughCount == 0)
        #expect(!controller.displayedIsProtected)
        #expect(!controller.displayedIsEvicted)
        #expect(controller.activePlaylistSnapshot?.rows.first?.skipCount == 0)
        #expect(controller.activePlaylistSnapshot?.rows.first?.playthroughCount == 0)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isProtected == false)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isEvicted == false)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
    }

    @Test("restore track refreshes displayed metadata")
    func restoreTrackRefreshesDisplayedMetadata() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            evictedAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedIsEvicted)

        try controller.restoreTrack(item, playlist: playlist, context: context)

        #expect(item.evictedAt == nil)
        #expect(!controller.displayedIsEvicted)
        #expect(controller.activePlaylistSnapshot?.rows.first?.isEvicted == false)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
    }

    @Test("retire and restore move tracks to bottom of destination order")
    func retireAndRestoreMoveTracksToBottomOfDestinationOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playerID = "test-\(UUID().uuidString)"
        let controller = PlaybackController(playerID: playerID)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-\(UUID().uuidString)",
            name: "Main",
            role: .oneTruePlaylist
        )
        let activeFirst = TrackRecord(title: "First", artistName: "Artist")
        let activeSecond = TrackRecord(title: "Second", artistName: "Artist")
        let changedTrack = TrackRecord(title: "Changed", artistName: "Artist")
        let retiredTrack = TrackRecord(title: "Retired", artistName: "Artist")
        let activeFirstItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: activeFirst.id,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let activeSecondItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: activeSecond.id,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let changedItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: changedTrack.id,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let retiredItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: retiredTrack.id,
            evictedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 5)
        )
        context.insert(playlist)
        [activeFirst, activeSecond, changedTrack, retiredTrack].forEach(context.insert)
        [activeFirstItem, activeSecondItem, changedItem, retiredItem].forEach(context.insert)
        try context.save()

        let activePlaylistID = playlist.musicPlaylistID
        let retiredPlaylistID = PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: activePlaylistID)
        defer {
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: activePlaylistID)
            PlaybackOrderStore.clear(playerID: playerID, musicPlaylistID: retiredPlaylistID)
        }

        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: activePlaylistID,
                orderedTrackIDs: [
                    changedTrack.id.uuidString,
                    activeSecond.id.uuidString,
                    activeFirst.id.uuidString
                ]
            )
        )

        try controller.retireTrack(changedItem, playlist: playlist, message: "Retired manually", context: context)

        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: activePlaylistID).orderedTrackIDs == [
            activeSecond.id.uuidString,
            activeFirst.id.uuidString
        ])
        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: retiredPlaylistID).orderedTrackIDs == [
            retiredTrack.id.uuidString,
            changedTrack.id.uuidString
        ])

        try controller.restoreTrack(changedItem, playlist: playlist, context: context)

        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: activePlaylistID).orderedTrackIDs == [
            activeSecond.id.uuidString,
            activeFirst.id.uuidString,
            changedTrack.id.uuidString
        ])
        #expect(PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: retiredPlaylistID).orderedTrackIDs == [
            retiredTrack.id.uuidString
        ])
    }
}
