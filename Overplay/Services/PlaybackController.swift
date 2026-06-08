import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackController {
    private struct PendingModeQueueRebuild {
        var playlistID: String
        var currentMusicItemID: String
        var currentLocalTrackID: String?
    }

    let playerID: String
    var currentTrack: CurrentPlaybackTrack?
    var currentPlaylistItem: PlaylistItemRecord?
    var elapsedSeconds: Double = 0
    var durationSeconds: Double?
    var isPlaying = false
    var currentPlaylistID: String?
    var statusMessage: String?
    private(set) var playbackItemMetadataVersion = 0
    private var playbackModeVersion = 0

    @ObservationIgnored private lazy var player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var warmUpTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: TrackPlaySession?
    @ObservationIgnored private var activeQueueLocalTrackIDs: [String] = []
    @ObservationIgnored private var activeQueueIndex: Int?
    @ObservationIgnored private var hasRestoredLocalPlaybackState = false
    @ObservationIgnored private var prefetchedArtworkTrackID: String?
    @ObservationIgnored private var isRestartingQueue = false
    @ObservationIgnored private var pendingModeQueueRebuild: PendingModeQueueRebuild?

    init(playerID: String = "main") {
        self.playerID = playerID
    }

    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }

    var canControlPlayback: Bool {
        currentPlaylistID != nil && currentTrack != nil && activeQueueIndex != nil
    }

    var displayedSkipCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.skipCount ?? currentTrack?.skipCount ?? 0
    }

    var displayedPlaythroughCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.playthroughCount ?? currentTrack?.playthroughCount ?? 0
    }

    var displayedIsProtected: Bool {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.protected == true || currentTrack?.protected == true
    }

    var displayedIsEvicted: Bool {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.evictedAt != nil || currentTrack?.isEvicted == true
    }

    var shuffleEnabled: Bool {
        _ = playbackModeVersion
        guard let currentPlaylistID else { return false }
        return PlaybackModeStore.state(playerID: playerID, musicPlaylistID: currentPlaylistID).shuffleEnabled
    }

    var repeatMode: MusicPlayer.RepeatMode {
        _ = playbackModeVersion
        return repeatEnabled ? .all : .none
    }

    var repeatEnabled: Bool {
        _ = playbackModeVersion
        guard let currentPlaylistID else { return false }
        return PlaybackModeStore.state(playerID: playerID, musicPlaylistID: currentPlaylistID).repeatEnabled
    }

    var repeatsSingleTrack: Bool {
        false
    }

    var repeatModeTitle: String {
        repeatEnabled ? "All" : "Off"
    }

    func playbackModeState(for musicPlaylistID: String) -> PlaybackModeState {
        _ = playbackModeVersion
        return PlaybackModeStore.state(playerID: playerID, musicPlaylistID: musicPlaylistID)
    }

    func startMonitoring(context: ModelContext) {
        guard monitorTask == nil else { return }
        disableMusicKitPlaybackModes()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refresh(context: context)
            }
        }
    }

    func schedulePostLaunchWarmUp() {
        guard warmUpTask == nil, monitorTask == nil, !isRunningTests else { return }
        warmUpTask = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.warmUpPlayerConnection()
            self?.clearWarmUpTask()
        }
    }

    private func warmUpPlayerConnection() async {
        disableMusicKitPlaybackModes()
        do {
            try await player.prepareToPlay()
        } catch {
            StartupProfiler.mark("Playback warm-up failed: \(error.localizedDescription)")
        }
    }

    private func clearWarmUpTask() {
        warmUpTask = nil
    }

    func clearLocalStateAfterDatabaseReset() {
        player.pause()
        currentTrack = nil
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        currentPlaylistID = nil
        activeSession = nil
        activeQueueLocalTrackIDs = []
        activeQueueIndex = nil
        prefetchedArtworkTrackID = nil
        pendingModeQueueRebuild = nil
        statusMessage = "Overplay data reset."
        hasRestoredLocalPlaybackState = false
        LocalPlaybackStateStore.clear()
        NowPlayingMetadataService.update(track: nil, elapsed: 0, isPlaying: false)
    }

    func restoreLocalPlaybackState(context: ModelContext) async {
        guard !hasRestoredLocalPlaybackState else { return }
        hasRestoredLocalPlaybackState = true

        guard let state = LocalPlaybackStateStore.load() else {
            return
        }

        do {
            guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: state.playlistID, in: context) else {
                return
            }

            let tracks = try await playableTracksForRestoration(
                playlist,
                preferFreshTracks: state.wasPlaying,
                context: context
            )
            let restoredLocalTrackID = state.localTrackID ?? (try? localTrackID(matching: state.musicItemID, context: context))
            let restorationItems = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let restorationTracks = try TrackRecordRepository.tracks(ids: restorationItems.map(\.trackID), in: context)
            let tracksByID = restorationTracks.firstValueDictionary(keyedBy: \.id)
            let musicTracksByLocalID = PlaybackQueueBuilder.musicTracksByLocalID(
                tracks,
                tracksByID: tracksByID
            )
            guard let startingTrack = restoredLocalTrackID.flatMap({ musicTracksByLocalID[$0] })
                ?? tracks.first(where: { $0.id.rawValue == state.musicItemID }) else {
                return
            }
            let restoredMusicItemID = startingTrack.id.rawValue

            warmUpTask?.cancel()
            warmUpTask = nil

            currentPlaylistID = state.playlistID
            elapsedSeconds = state.elapsedSeconds
            isPlaying = false
            currentPlaylistItem = try restoredLocalTrackID.flatMap { try playlistItem(localTrackID: $0, context: context) }
                ?? playlistItem(matching: restoredMusicItemID, context: context)
            currentTrack = currentPlaybackTrack(
                musicItemID: restoredMusicItemID,
                playlistItem: currentPlaylistItem,
                context: context
            )
            durationSeconds = currentTrack?.durationSeconds
            statusMessage = nil
            disableMusicKitPlaybackModes()
            let startingLocalTrackID = currentPlaylistItem?.trackID.uuidString ?? restoredLocalTrackID
            let queueEntries = try orderedQueueEntries(
                from: tracks,
                playlistID: state.playlistID,
                startingTrackID: startingLocalTrackID,
                promoteStartingTrackInShuffle: false,
                context: context
            )
            let queueTracks = queueTracks(from: queueEntries, fallback: tracks)
            let queueStartingTrack = queueTracks.first { $0.id == startingTrack.id } ?? startingTrack
            pendingModeQueueRebuild = nil
            updateActiveQueue(entries: queueEntries, startingAt: startingLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(for: queueTracks, startingAt: queueStartingTrack)
            if state.wasPlaying {
                let isPrepared = await prepareRestoredQueue(seekTo: state.elapsedSeconds)
                if isPrepared {
                    do {
                        try await player.play()
                        startMonitoring(context: context)
                        isPlaying = true
                    } catch {
                        player.pause()
                        isPlaying = false
                        statusMessage = "Restored playback paused: \(error.localizedDescription)"
                    }
                } else {
                    player.pause()
                    isPlaying = false
                }
            } else {
                player.pause()
                player.playbackTime = state.elapsedSeconds
            }
            NowPlayingMetadataService.update(track: currentTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
            prefetchCurrentArtworkIfNeeded(musicItemID: restoredMusicItemID, playlistID: state.playlistID)
        } catch {
            statusMessage = "Could not restore playback: \(error.localizedDescription)"
        }
    }

    func restoreLocalPlaybackDisplay(context: ModelContext) {
        guard currentTrack == nil else { return }
        guard let state = LocalPlaybackStateStore.load() else { return }

        do {
            guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: state.playlistID, in: context) else {
                return
            }
            guard let restored = try restoredTrackAndItem(
                from: state,
                playlist: playlist,
                context: context
            ) else {
                return
            }

            currentPlaylistID = playlist.musicPlaylistID
            currentPlaylistItem = restored.item
            currentTrack = CurrentPlaybackTrack(
                restored.track,
                musicItemID: state.musicItemID,
                item: restored.item
            )
            elapsedSeconds = state.elapsedSeconds
            durationSeconds = restored.track.durationSeconds
            isPlaying = false
            activeSession = PlaybackSessionSupport.makeSession(
                trackID: state.musicItemID,
                elapsedSeconds: state.elapsedSeconds,
                durationSeconds: restored.track.durationSeconds,
                sessionStartDate: state.updatedAt
            )
            activeQueueLocalTrackIDs = []
            activeQueueIndex = nil
            statusMessage = nil
            bumpPlaybackItemMetadataVersion()
        } catch {
            StartupProfiler.mark("Local playback display restore failed: \(error.localizedDescription)")
        }
    }

    func playPlaylist(settings: OverplaySettings, context: ModelContext) async {
        guard let playlistID = settings.selectedPlaylistID else {
            statusMessage = "Choose a playlist first."
            return
        }

        if let playlist = try? PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) {
            await playPlaylist(playlist, settings: settings, context: context)
        } else {
            statusMessage = "Selected playlist is not linked locally. Sync or choose a playlist before playing."
        }
    }

    func playPlaylist(_ playlist: PlaylistRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(playlist, startingAt: nil, context: context)
    }

    func playPlaylist(_ playlist: PlaylistRecord, startingAt track: TrackRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(playlist, startingAt: track, context: context)
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    private func playPlaylist(_ playlist: PlaylistRecord, startingAt trackRecord: TrackRecord?, context: ModelContext) async {
        do {
            let startingTrackID = trackRecord?.id.uuidString
            let queueEntries = try orderedCachedQueueEntries(
                for: playlist.musicPlaylistID,
                startingTrackID: startingTrackID,
                promoteStartingTrackInShuffle: false,
                context: context
            )
            guard !queueEntries.isEmpty else {
                statusMessage = "No locally cached playable tracks for \(playlist.name). Sync this playlist before playing."
                return
            }
            if let startingTrackID,
               !queueEntries.contains(where: { $0.localTrackID == startingTrackID }) {
                statusMessage = "That track is not playable in this playlist."
                return
            }

            try await startPlayback(
                queueEntries: queueEntries,
                playlistID: playlist.musicPlaylistID,
                startingAt: startingTrackID,
                context: context
            )
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
        }
    }

    private func cachedPlayableMusicTracks(for playlist: PlaylistRecord, in context: ModelContext) throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        return PlaybackQueueBuilder.cachedPlayableMusicTracks(items: items, tracksByID: tracksByID)
    }

    private func playableTracksForRestoration(
        _ playlist: PlaylistRecord,
        preferFreshTracks: Bool = false,
        context: ModelContext
    ) async throws -> [Track] {
        _ = preferFreshTracks
        return try cachedPlayableMusicTracks(for: playlist, in: context)
    }

    private func prepareRestoredQueue(seekTo elapsedSeconds: Double) async -> Bool {
        do {
            try await player.prepareToPlay()
            player.playbackTime = elapsedSeconds
            return true
        } catch {
            player.pause()
            self.elapsedSeconds = elapsedSeconds
            statusMessage = "Restored playback paused: \(error.localizedDescription)"
            return false
        }
    }

    private func playlistPlaybackInputs(
        for playlistID: String,
        context: ModelContext
    ) throws -> (playlist: PlaylistRecord, items: [PlaylistItemRecord], tracksByID: [UUID: TrackRecord]) {
        guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) else {
            throw PlaylistSyncError.playlistNotFound
        }

        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        return (playlist, items, tracksByID)
    }

    private func orderedQueueTracks(
        from tracks: [Track],
        playlistID: String,
        startingTrackID: String?,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        context: ModelContext
    ) throws -> [Track] {
        let entries = try orderedQueueEntries(
            from: tracks,
            playlistID: playlistID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID,
            context: context
        )
        return entries.isEmpty ? tracks : entries.map(\.musicTrack)
    }

    private func queueTracks(from entries: [PlaybackQueueEntry], fallback tracks: [Track]) -> [Track] {
        PlaybackQueueCoordinator.queueTracks(from: entries, fallback: tracks)
    }

    private func orderedQueueEntries(
        from tracks: [Track],
        playlistID: String,
        startingTrackID: String?,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistPlaybackInputs(for: playlistID, context: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        let orderedTrackIDs = PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID
        )

        let musicTracksByLocalID = PlaybackQueueCoordinator.musicTracksByLocalID(
            tracks,
            tracksByID: inputs.tracksByID
        )
        return orderedTrackIDs.compactMap { localTrackID in
            musicTracksByLocalID[localTrackID].map {
                PlaybackQueueEntry(localTrackID: localTrackID, musicTrack: $0)
            }
        }
    }

    private func orderedCachedQueueEntries(
        for playlistID: String,
        startingTrackID: String? = nil,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistPlaybackInputs(for: playlistID, context: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        let orderedTrackIDs = PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID
        )

        return PlaybackQueueCoordinator.cachedEntries(orderedTrackIDs: orderedTrackIDs, tracksByID: inputs.tracksByID)
    }

    private func cachedQueueEntries(
        orderedTrackIDs: [String],
        tracksByID: [UUID: TrackRecord]
    ) throws -> [PlaybackQueueEntry] {
        PlaybackQueueCoordinator.cachedEntries(orderedTrackIDs: orderedTrackIDs, tracksByID: tracksByID)
    }

    private func orderedLocalTrackIDs(
        for playlistID: String,
        retaining retainedTrackID: String?,
        context: ModelContext
    ) throws -> [String] {
        let inputs = try playlistPlaybackInputs(for: playlistID, context: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        return PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            retainedTrackID: retainedTrackID
        )
    }

    private func localTrackID(matching musicItemID: String, context: ModelContext) throws -> String? {
        try PlaybackQueueCoordinator.localTrackID(matching: musicItemID, context: context)
    }

    private var activeQueueCurrentLocalTrackID: String? {
        guard let activeQueueIndex,
              activeQueueLocalTrackIDs.indices.contains(activeQueueIndex) else {
            return nil
        }

        return activeQueueLocalTrackIDs[activeQueueIndex]
    }

    private func updateActiveQueue(entries: [PlaybackQueueEntry], startingAt localTrackID: String?) {
        let state = PlaybackQueueCoordinator.activeQueueState(entries: entries, startingAt: localTrackID)
        activeQueueLocalTrackIDs = state.localTrackIDs
        activeQueueIndex = state.index
    }

    private func updateActiveQueueCurrentTrackID(_ localTrackID: String?) {
        activeQueueIndex = PlaybackQueueCoordinator.updatedActiveQueueIndex(
            localTrackID: localTrackID,
            activeQueueLocalTrackIDs: activeQueueLocalTrackIDs,
            currentIndex: activeQueueIndex
        )
    }

    private func advanceActiveQueueIndex(by offset: Int) {
        activeQueueIndex = PlaybackQueueCoordinator.advancedActiveQueueIndex(
            by: offset,
            activeQueueLocalTrackIDs: activeQueueLocalTrackIDs,
            currentIndex: activeQueueIndex
        )
    }

    private func disableMusicKitPlaybackModes() {
        player.state.shuffleMode = .off
        player.state.repeatMode = MusicPlayer.RepeatMode.none
    }

    private func musicPlaybackFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "MPMusicPlayerControllerErrorDomain" {
            return """
            Apple Music playback could not start. Check Apple Music access, the signed-in Apple Music account, and whether this run destination supports Apple Music playback. \(error.localizedDescription)
            """
        }

        return error.localizedDescription
    }

    private func startPlayback(
        queueEntries: [PlaybackQueueEntry],
        playlistID: String,
        startingAt localTrackID: String?,
        context: ModelContext
    ) async throws {
        guard !queueEntries.isEmpty else {
            statusMessage = "No playable tracks remain after local evictions."
            return
        }

        warmUpTask?.cancel()
        warmUpTask = nil

        disableMusicKitPlaybackModes()
        let queueTracks = queueEntries.map(\.musicTrack)
        let queueStartingTrack = localTrackID.flatMap { localTrackID in
            queueEntries.first { $0.localTrackID == localTrackID }?.musicTrack
        }
        pendingModeQueueRebuild = nil
        updateActiveQueue(entries: queueEntries, startingAt: localTrackID)
        player.queue = ApplicationMusicPlayer.Queue(for: queueTracks, startingAt: queueStartingTrack)
        try await player.play()
        currentPlaylistID = playlistID
        await ArtworkCacheService.shared.touchPlaylistUsage(playlistID)
        statusMessage = nil
        startMonitoring(context: context)
        await refresh(context: context)
    }

    func togglePlayPause(context: ModelContext) async {
        do {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                try await player.play()
                startMonitoring(context: context)
            }
            await refresh(context: context)
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
        }
    }

    func play(context: ModelContext) async {
        do {
            try await player.play()
            startMonitoring(context: context)
            await refresh(context: context)
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        if let musicItemID = currentTrack?.id {
            persistLocalPlaybackState(musicItemID: musicItemID)
        }
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        let skippedTrackID = activeSession?.trackID ?? currentTrack?.id
        await evaluateActiveSession(settings: settings, context: context, naturalCompletion: false)
        if let skippedTrackID,
           await applyPendingModeQueueRebuild(after: skippedTrackID, movingForward: true, context: context) {
            return
        }

        do {
            try await player.skipToNextEntry()
            advanceActiveQueueIndex(by: 1)
            await refresh(context: context)
        } catch {
            if let skippedTrackID,
               await handleQueueEnded(lastMusicItemID: skippedTrackID, context: context) {
                return
            }
            statusMessage = error.localizedDescription
        }
    }

    func previous(context: ModelContext) async {
        markActiveSessionEvaluatedWithoutSkip()
        if let currentTrackID = activeSession?.trackID ?? currentTrack?.id,
           await applyPendingModeQueueRebuild(after: currentTrackID, movingForward: false, context: context) {
            return
        }

        do {
            try await player.skipToPreviousEntry()
            advanceActiveQueueIndex(by: -1)
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleShuffle(context: ModelContext) async {
        await setShuffleEnabled(!shuffleEnabled, context: context)
    }

    func setShuffleEnabled(_ isEnabled: Bool, context: ModelContext) async {
        guard let currentPlaylistID else {
            statusMessage = "Choose a playlist first."
            return
        }

        do {
            let inputs = try playlistPlaybackInputs(for: currentPlaylistID, context: context)
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
            let currentLocalTrackID = currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID
                ?? currentTrack.flatMap { try? localTrackID(matching: $0.id, context: context) }
            PlaybackModeCoordinator.setShuffleEnabled(
                isEnabled,
                playerID: playerID,
                playlistID: currentPlaylistID,
                orderTracks: orderTracks,
                currentLocalTrackID: currentLocalTrackID
            )
            disableMusicKitPlaybackModes()
            playbackModeVersion += 1

            if let currentMusicItemID = player.queue.currentEntry?.item?.id.rawValue ?? currentTrack?.id {
                pendingModeQueueRebuild = PendingModeQueueRebuild(
                    playlistID: currentPlaylistID,
                    currentMusicItemID: currentMusicItemID,
                    currentLocalTrackID: currentLocalTrackID
                )
            } else {
                await rebuildCurrentQueue(context: context)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleRepeat() {
        setRepeatEnabled(!repeatEnabled)
    }

    func setRepeatEnabled(_ isEnabled: Bool) {
        guard let currentPlaylistID else {
            statusMessage = "Choose a playlist first."
            return
        }

        PlaybackModeCoordinator.setRepeatEnabled(isEnabled, playerID: playerID, playlistID: currentPlaylistID)
        disableMusicKitPlaybackModes()
        playbackModeVersion += 1
    }

    func cycleRepeatMode() {
        toggleRepeat()
    }

    func setRepeatMode(_ repeatMode: MusicPlayer.RepeatMode) {
        setRepeatEnabled(repeatMode != .none)
    }

    private func rebuildCurrentQueue(context: ModelContext) async {
        guard let currentPlaylistID,
              (try? currentPlaylist(in: context)) != nil else {
            return
        }

        let currentMusicItemID = player.queue.currentEntry?.item?.id.rawValue ?? currentTrack?.id
        let playbackTime = player.playbackTime
        let shouldResumePlayback = player.state.playbackStatus == .playing

        do {
            let currentLocalTrackID = currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID
                ?? currentMusicItemID.flatMap { try? localTrackID(matching: $0, context: context) }
            let queueEntries = try orderedCachedQueueEntries(
                for: currentPlaylistID,
                retainedTrackID: currentLocalTrackID,
                context: context
            )
            let queueTracks = queueEntries.map(\.musicTrack)
            guard !queueTracks.isEmpty else { return }
            let startingTrack = currentLocalTrackID.flatMap { localTrackID in
                queueEntries.first { $0.localTrackID == localTrackID }?.musicTrack
            } ?? currentMusicItemID.flatMap { musicItemID in
                queueTracks.first { $0.id.rawValue == musicItemID }
            }

            disableMusicKitPlaybackModes()
            pendingModeQueueRebuild = nil
            updateActiveQueue(entries: queueEntries, startingAt: currentLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(for: queueTracks, startingAt: startingTrack)
            if startingTrack != nil {
                player.playbackTime = playbackTime
            }

            if shouldResumePlayback {
                try await player.play()
            } else {
                player.pause()
            }
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func keepCurrent(settings: OverplaySettings, context: ModelContext) {
        guard let musicItemID = currentTrack?.id,
              let playlist = try? currentPlaylist(in: context),
              let item = try? PlaybackSessionSupport.resolvePlaylistItem(
                  forMusicItemID: musicItemID,
                  currentPlaylistItem: currentPlaylistItem,
                  playlist: playlist,
                  in: context
              ) else {
            statusMessage = "Choose a linked playlist track to keep."
            return
        }

        do {
            try TrackHealthActionService.keepCurrentTrack(
                item,
                playlist: playlist,
                protect: settings.protectKeptTracks,
                message: "Kept by user",
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        currentPlaylistItem = item
        syncPlaybackMetadata(for: musicItemID, context: context)
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
        guard let musicItemID = currentTrack?.id,
              let playlist = try? currentPlaylist(in: context),
              let item = try? PlaybackSessionSupport.resolvePlaylistItem(
                  forMusicItemID: musicItemID,
                  currentPlaylistItem: currentPlaylistItem,
                  playlist: playlist,
                  in: context
              ) else {
            statusMessage = "Choose a linked playlist track to evict."
            return
        }

        do {
            try TrackHealthActionService.evictTrack(
                item,
                playlist: playlist,
                message: "Evicted manually",
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        currentPlaylistItem = item
        await removeEvictedItemFromPlaylist(item, playlist: playlist, context: context)
        await next(settings: settings, context: context)
    }

    private func refresh(context: ModelContext) async {
        let oldTrackID = activeSession?.trackID
        let newTrackID = resolvedCurrentMusicItemID(context: context)
        elapsedSeconds = player.playbackTime
        isPlaying = player.state.playbackStatus == .playing

        if let oldTrackID, newTrackID == nil, !isRestartingQueue {
            if let settings = try? SettingsRepository.settings(in: context) {
                await evaluateActiveSession(settings: settings, context: context, naturalCompletion: true)
            }

            if await applyPendingModeQueueRebuild(after: oldTrackID, movingForward: true, context: context) {
                return
            }

            if await handleQueueEnded(lastMusicItemID: oldTrackID, context: context) {
                return
            }
        }

        if oldTrackID != nil, newTrackID != nil, oldTrackID != newTrackID, let settings = try? SettingsRepository.settings(in: context) {
            await evaluateActiveSession(settings: settings, context: context, naturalCompletion: false)
        }

        if let oldTrackID, newTrackID != nil, oldTrackID != newTrackID {
            if await applyPendingModeQueueRebuild(after: oldTrackID, movingForward: true, context: context) {
                return
            }
        }

        if let newTrackID {
            currentPlaylistItem = try? playlistItem(matching: newTrackID, context: context)
            updateActiveQueueCurrentTrackID(currentPlaylistItem?.trackID.uuidString)
            syncPlaybackMetadata(for: newTrackID, context: context)
            durationSeconds = currentTrack?.durationSeconds
            prefetchCurrentArtworkIfNeeded(musicItemID: newTrackID, playlistID: currentPlaylistID)

            if let activeSession, activeSession.trackID == newTrackID {
                self.activeSession = PlaybackSessionEvaluationService.updateObservedProgress(
                    activeSession,
                    elapsedSeconds: elapsedSeconds,
                    durationSeconds: durationSeconds
                )
            } else {
                activeSession = PlaybackSessionEvaluationService.bootstrapSession(
                    trackID: newTrackID,
                    elapsedSeconds: elapsedSeconds,
                    durationSeconds: durationSeconds
                )
            }

            evaluatePlaythroughIfNeeded(context: context)
            reconcileCurrentPlaybackOrder(context: context)
        } else if currentTrack != nil || currentPlaylistID != nil {
            if let activeSession {
                self.activeSession = PlaybackSessionEvaluationService.updateObservedProgress(
                    activeSession,
                    elapsedSeconds: elapsedSeconds,
                    durationSeconds: durationSeconds ?? currentTrack?.durationSeconds
                )
            }
            if let musicItemID = currentTrack?.id {
                syncPlaybackMetadata(for: musicItemID, context: context)
            }
        } else {
            currentTrack = nil
            currentPlaylistItem = nil
            durationSeconds = nil
            activeSession = nil
            activeQueueLocalTrackIDs = []
            activeQueueIndex = nil
            currentPlaylistID = nil
            prefetchedArtworkTrackID = nil
        }

        NowPlayingMetadataService.update(track: currentTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)

        if let newTrackID {
            persistLocalPlaybackState(musicItemID: newTrackID)
        }
    }

    private func evaluatePlaythroughIfNeeded(context: ModelContext) {
        guard let settings = try? SettingsRepository.settings(in: context) else { return }
        do {
            let outcome = try PlaybackSessionEvaluationService.evaluatePlaythroughIfNeeded(
                session: activeSession,
                currentPlaylistItem: currentPlaylistItem,
                playlist: currentPlaylist(in: context),
                settings: settings,
                context: context
            )
            applyEvaluationOutcome(outcome, context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeEvictedItemFromPlaylist(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async {
        guard item.evictedAt != nil else { return }
        guard PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(item: item, playlist: playlist) else {
            statusMessage = if playlist.role != .oneTruePlaylist {
                "Evicted locally. Remote deletes only apply to the One True Playlist."
            } else {
                "Evicted locally. \(playlist.name) is incoming only, so Apple Music was not changed."
            }
            return
        }
        let trackID = currentTrack?.id
            ?? (try? TrackRecordRepository.track(id: item.trackID, in: context)?.catalogID)
            ?? (try? TrackRecordRepository.track(id: item.trackID, in: context)?.libraryID)
        guard let trackID else { return }

        do {
            try await PlaylistSyncService().removeTrackFromPlaylist(trackID: trackID, playlistID: playlist.musicPlaylistID)
            statusMessage = "Removed \(currentTrack?.title ?? "track") from the Apple Music playlist."
        } catch {
            statusMessage = "Evicted locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
        }
    }

    private func evaluateActiveSession(settings: OverplaySettings, context: ModelContext, naturalCompletion: Bool) async {
        do {
            let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
                activeSession: activeSession,
                currentTrackID: currentTrack?.id,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds ?? currentTrack?.durationSeconds,
                currentPlaylistItem: currentPlaylistItem,
                playlist: currentPlaylist(in: context),
                settings: settings,
                naturalCompletion: naturalCompletion,
                context: context
            )
            applyEvaluationOutcome(outcome, context: context)

            if let outcome, outcome.evictedDuringEvaluation, let item = outcome.item, let playlist = outcome.playlist {
                await removeEvictedItemFromPlaylist(item, playlist: playlist, context: context)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyEvaluationOutcome(_ outcome: PlaybackSessionEvaluationService.EvaluationOutcome?, context: ModelContext) {
        guard let outcome else { return }
        activeSession = outcome.session
        if let item = outcome.item {
            currentPlaylistItem = item
        }
        if outcome.shouldSyncPlaybackMetadata {
            syncPlaybackMetadata(for: outcome.session.trackID, context: context)
        }
    }

    private func currentPlaylist(in context: ModelContext) throws -> PlaylistRecord? {
        try PlaybackTrackResolver.currentPlaylist(musicPlaylistID: currentPlaylistID, in: context)
    }

    private func playlistItem(matching musicItemID: String, context: ModelContext) throws -> PlaylistItemRecord? {
        try PlaybackTrackResolver.playlistItem(
            matching: musicItemID,
            musicPlaylistID: currentPlaylistID,
            currentPlaylistItem: currentPlaylistItem,
            in: context
        )
    }

    private func playlistItem(localTrackID: String, context: ModelContext) throws -> PlaylistItemRecord? {
        try PlaybackTrackResolver.playlistItem(
            localTrackID: localTrackID,
            musicPlaylistID: currentPlaylistID,
            in: context
        )
    }

    private func restoredTrackAndItem(
        from state: LocalPlaybackState,
        playlist: PlaylistRecord,
        context: ModelContext
    ) throws -> (track: TrackRecord, item: PlaylistItemRecord?)? {
        try PlaybackTrackResolver.restoredTrackAndItem(from: state, playlist: playlist, in: context)
    }

    private func currentPlaybackTrack(
        musicItemID: String,
        playlistItem: PlaylistItemRecord?,
        context: ModelContext
    ) -> CurrentPlaybackTrack? {
        PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: musicItemID,
            playlistItem: playlistItem,
            musicPlaylistID: currentPlaylistID,
            queueItem: player.queue.currentEntry?.item,
            in: context
        )
    }

    private func refreshCurrentTrackMetadata(context: ModelContext) {
        guard let musicItemID = currentTrack?.id else { return }
        currentTrack = currentPlaybackTrack(
            musicItemID: musicItemID,
            playlistItem: currentPlaylistItem,
            context: context
        )
        bumpPlaybackItemMetadataVersion()
    }

    private func syncPlaybackMetadata(for musicItemID: String, context: ModelContext) {
        if let playlist = try? currentPlaylist(in: context),
           let item = try? PlaybackSessionSupport.resolvePlaylistItem(
               forMusicItemID: musicItemID,
               currentPlaylistItem: currentPlaylistItem,
               playlist: playlist,
               in: context
           ) {
            currentPlaylistItem = item
        }

        if currentTrack?.id == musicItemID {
            refreshCurrentTrackMetadata(context: context)
        } else {
            currentTrack = currentPlaybackTrack(
                musicItemID: musicItemID,
                playlistItem: currentPlaylistItem,
                context: context
            )
            bumpPlaybackItemMetadataVersion()
        }
    }

    private func markActiveSessionEvaluatedWithoutSkip() {
        activeSession = PlaybackSessionEvaluationService.markEvaluatedWithoutSkip(
            activeSession: activeSession,
            currentTrackID: currentTrack?.id,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds ?? currentTrack?.durationSeconds
        )
    }

    private func bumpPlaybackItemMetadataVersion() {
        playbackItemMetadataVersion += 1
    }

    private func resolvedCurrentMusicItemID(context: ModelContext) -> String? {
        if let queueReportedTrackID = player.queue.currentEntry?.item?.id.rawValue {
            if let localTrackID = try? localTrackID(matching: queueReportedTrackID, context: context) {
                updateActiveQueueCurrentTrackID(localTrackID)
            }
            return queueReportedTrackID
        }

        return activeSession?.trackID ?? currentTrack?.id
    }

    private func prefetchCurrentArtworkIfNeeded(musicItemID: String, playlistID: String?) {
        guard prefetchedArtworkTrackID != musicItemID,
              let artworkURLTemplate = currentTrack?.artworkURLTemplate else {
            return
        }

        prefetchedArtworkTrackID = musicItemID
        Task(priority: .userInitiated) {
            await ArtworkCacheService.shared.artworkFileURL(
                for: artworkURLTemplate,
                pixelSize: 512,
                playlistID: playlistID,
                priority: .userInitiated,
                protectedPlaylistID: playlistID
            )
        }
    }

    private func persistLocalPlaybackState(musicItemID: String) {
        guard let currentPlaylistID else {
            return
        }

        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: currentPlaylistID,
            musicItemID: musicItemID,
            elapsedSeconds: elapsedSeconds,
            wasPlaying: isPlaying,
            updatedAt: .now,
            localTrackID: currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID
        ))
    }

    private func handleQueueEnded(lastMusicItemID: String, context: ModelContext) async -> Bool {
        guard let currentPlaylistID,
              PlaybackModeStore.state(playerID: playerID, musicPlaylistID: currentPlaylistID).repeatEnabled,
              (try? currentPlaylist(in: context)) != nil,
              !isRestartingQueue else {
            return false
        }

        isRestartingQueue = true
        defer { isRestartingQueue = false }

        do {
            let inputs = try playlistPlaybackInputs(for: currentPlaylistID, context: context)
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
            let lastLocalTrackID = try localTrackID(matching: lastMusicItemID, context: context)
            let restartOrder = PlaybackModeCoordinator.repeatRestartOrder(
                orderTracks: orderTracks,
                playerID: playerID,
                playlistID: currentPlaylistID,
                lastLocalTrackID: lastLocalTrackID
            )
            if restartOrder.didUpdateStoredShuffleOrder {
                playbackModeVersion += 1
            }

            let queueEntries = try cachedQueueEntries(orderedTrackIDs: restartOrder.orderedTrackIDs, tracksByID: inputs.tracksByID)
            let queueTracks = queueEntries.map(\.musicTrack)
            guard !queueEntries.isEmpty else { return false }

            disableMusicKitPlaybackModes()
            activeQueueLocalTrackIDs = queueEntries.map(\.localTrackID)
            activeQueueIndex = activeQueueLocalTrackIDs.isEmpty ? nil : activeQueueLocalTrackIDs.startIndex
            player.queue = ApplicationMusicPlayer.Queue(for: queueTracks)
            try await player.play()
            await refresh(context: context)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func applyPendingModeQueueRebuild(
        after lastMusicItemID: String,
        movingForward: Bool,
        context: ModelContext
    ) async -> Bool {
        guard let pendingModeQueueRebuild,
              pendingModeQueueRebuild.playlistID == currentPlaylistID,
              (try? currentPlaylist(in: context)) != nil else {
            return false
        }

        do {
            let anchorLocalTrackID = pendingModeQueueRebuild.currentLocalTrackID
                ?? (try? localTrackID(matching: pendingModeQueueRebuild.currentMusicItemID, context: context))
                ?? (try? localTrackID(matching: lastMusicItemID, context: context))
            guard let anchorLocalTrackID else {
                return false
            }

            let queueEntries = try orderedCachedQueueEntries(
                for: pendingModeQueueRebuild.playlistID,
                retainedTrackID: anchorLocalTrackID,
                context: context
            )
            let queueTracks = queueEntries.map(\.musicTrack)
            guard !queueTracks.isEmpty else { return false }
            let availableLocalTrackIDs = Set(queueEntries.map(\.localTrackID))
            let orderedLocalTrackIDs = try orderedLocalTrackIDs(
                for: pendingModeQueueRebuild.playlistID,
                retaining: anchorLocalTrackID,
                context: context
            )

            if movingForward,
               PlaybackModeCoordinator.adjacentAvailableID(
                   to: anchorLocalTrackID,
                   orderedLocalTrackIDs: orderedLocalTrackIDs,
                   availableIDs: availableLocalTrackIDs,
                   movingForward: true
               ) == nil,
               PlaybackModeStore.state(playerID: playerID, musicPlaylistID: pendingModeQueueRebuild.playlistID).repeatEnabled {
                self.pendingModeQueueRebuild = nil
                return await handleQueueEnded(lastMusicItemID: pendingModeQueueRebuild.currentMusicItemID, context: context)
            }

            guard let startingLocalTrackID = PlaybackModeCoordinator.adjacentAvailableID(
                to: anchorLocalTrackID,
                orderedLocalTrackIDs: orderedLocalTrackIDs,
                availableIDs: availableLocalTrackIDs,
                movingForward: movingForward
            ), let startingTrack = queueEntries.first(where: { $0.localTrackID == startingLocalTrackID })?.musicTrack else {
                if movingForward,
                   let lastTrack = queueEntries.first(where: { $0.localTrackID == anchorLocalTrackID })?.musicTrack {
                    let transitionEntries = PlaybackQueueCoordinator.transitionEntries(from: queueEntries, startingAt: anchorLocalTrackID)
                    let transitionTracks = transitionEntries.map(\.musicTrack)
                    disableMusicKitPlaybackModes()
                    updateActiveQueue(entries: transitionEntries, startingAt: anchorLocalTrackID)
                    player.queue = ApplicationMusicPlayer.Queue(for: transitionTracks, startingAt: lastTrack)
                    player.pause()
                    self.pendingModeQueueRebuild = nil
                    await refresh(context: context)
                    return true
                }

                return false
            }

            let shouldResumePlayback = player.state.playbackStatus == .playing
            let transitionEntries = PlaybackQueueCoordinator.transitionEntries(from: queueEntries, startingAt: startingLocalTrackID)
            let transitionTracks = transitionEntries.map(\.musicTrack)
            disableMusicKitPlaybackModes()
            updateActiveQueue(entries: transitionEntries, startingAt: startingLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(for: transitionTracks, startingAt: startingTrack)
            if shouldResumePlayback {
                try await player.play()
            } else {
                player.pause()
            }

            self.pendingModeQueueRebuild = nil
            await refresh(context: context)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func reconcileStoredOrder(for playlist: PlaylistRecord, context: ModelContext) {
        let currentLocalTrackID = currentPlaylistID == playlist.musicPlaylistID ? currentPlaylistItem?.trackID.uuidString : nil
        do {
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: items)
            var state = PlaybackModeStore.state(playerID: playerID, musicPlaylistID: playlist.musicPlaylistID)
            guard state.shuffleEnabled else { return }

            let reconciledOrder = PlaybackModeCoordinator.reconciledStoredOrder(
                storedOrder: state.orderedTrackIDs,
                orderTracks: orderTracks,
                currentTrackID: currentLocalTrackID
            )
            if state.orderedTrackIDs != reconciledOrder {
                state.orderedTrackIDs = reconciledOrder
                PlaybackModeStore.save(state)
                playbackModeVersion += 1
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func reconcileCurrentPlaybackOrder(context: ModelContext) {
        guard currentPlaylistID != nil,
              let playlist = try? currentPlaylist(in: context) else {
            return
        }

        reconcileStoredOrder(for: playlist, context: context)
    }

    func evaluateActiveSessionForTesting(
        settings: OverplaySettings,
        context: ModelContext,
        naturalCompletion: Bool
    ) async {
        await evaluateActiveSession(settings: settings, context: context, naturalCompletion: naturalCompletion)
    }

    func markActiveSessionEvaluatedWithoutSkipForTesting() {
        markActiveSessionEvaluatedWithoutSkip()
    }
}
