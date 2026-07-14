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

    private struct LocalPlaybackStateIdentity: Equatable {
        var playlistID: String
        var musicItemID: String
        var localTrackID: String?
    }

    private struct CurrentPlaybackIdentity {
        var musicItemID: String
        var localTrackID: String?
        var playlistItemID: UUID?
        var isQueueCorrelated: Bool
        var source: String
    }

    private struct CurrentPlaybackTarget {
        var musicItemID: String
        var playlist: PlaylistRecord
        var item: PlaylistItemRecord
    }

    let playerID: String
    var currentTrack: CurrentPlaybackTrack?
    var musicKitNowPlayingTrack: CurrentPlaybackTrack?
    var isMusicKitNowPlayingTrackPending = false
    var currentPlaylistItem: PlaylistItemRecord?
    var elapsedSeconds: Double = 0
    var durationSeconds: Double?
    var isPlaying = false
    var currentPlaylistID: String?
    var activePlaylistSnapshot: ActivePlaylistSnapshot?
    var statusMessage: String?
    private(set) var playbackItemMetadataVersion = 0
    private var playbackModeVersion = 0

    @ObservationIgnored private lazy var player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var warmUpTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: TrackPlaySession?
    @ObservationIgnored private var activeQueueEntries: [RealizedPlaybackQueueEntry] = []
    @ObservationIgnored private var activeQueueIndex: Int?
    @ObservationIgnored private var hasRestoredLocalPlaybackState = false
    @ObservationIgnored private var prefetchedArtworkTrackID: String?
    @ObservationIgnored private var isRestartingQueue = false
    @ObservationIgnored private var pendingModeQueueRebuild: PendingModeQueueRebuild?
    @ObservationIgnored private var pendingQueueAdvanceLocalTrackID: String?
    @ObservationIgnored private var pendingQueueAdvanceStartedAt: Date?
    @ObservationIgnored private var lastLocalPlaybackStateFlushAt: Date?
    @ObservationIgnored private var lastLocalPlaybackStateIdentity: LocalPlaybackStateIdentity?
    @ObservationIgnored private var lastLoggedPlaybackRefreshSignature: String?

    init(playerID: String = "main") {
        self.playerID = playerID
    }

    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }

    var nowPlayingDisplayTrack: CurrentPlaybackTrack? {
        if isMusicKitNowPlayingTrackPending {
            return musicKitNowPlayingTrack
        }

        return musicKitNowPlayingTrack ?? currentTrack
    }

    var nowPlayingDisplayLocalTrackID: String? {
        activeQueueCurrentLocalTrackID ?? currentPlaylistItem?.trackID.uuidString ?? activeSession?.localTrackID
    }

    var canControlPlayback: Bool {
        currentPlaylistID != nil && currentTrack != nil && activeQueueIndex != nil
    }

    var displayedSkipCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.skipCount ?? currentTrack?.skipCount ?? 0
    }

    func displayedSkipCount(context: ModelContext) -> Int {
        _ = playbackItemMetadataVersion
        let item = displayedPlaylistItem(context: context)
        if let item,
           let currentTrack,
           item.skipCount != currentTrack.skipCount {
            TrackMetadataDiagnostics.log(
                "displayed skip count mismatch liveItem=\(TrackMetadataDiagnostics.describe(item)) snapshot=\(TrackMetadataDiagnostics.describe(currentTrack)) displayed=\(item.skipCount)"
            )
        }
        return item?.skipCount ?? currentTrack?.skipCount ?? 0
    }

    var displayedPlaythroughCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.playthroughCount ?? currentTrack?.playthroughCount ?? 0
    }

    func displayedPlaythroughCount(context: ModelContext) -> Int {
        _ = playbackItemMetadataVersion
        return displayedPlaylistItem(context: context)?.playthroughCount ?? currentTrack?.playthroughCount ?? 0
    }

    var displayedIsProtected: Bool {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.protected == true || currentTrack?.protected == true
    }

    func displayedIsProtected(context: ModelContext) -> Bool {
        _ = playbackItemMetadataVersion
        return displayedPlaylistItem(context: context)?.protected == true || currentTrack?.protected == true
    }

    var displayedIsEvicted: Bool {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.evictedAt != nil || currentTrack?.isEvicted == true
    }

    func displayedIsEvicted(context: ModelContext) -> Bool {
        _ = playbackItemMetadataVersion
        return displayedPlaylistItem(context: context)?.evictedAt != nil || currentTrack?.isEvicted == true
    }

    var shuffleEnabled: Bool {
        _ = playbackModeVersion
        return false
    }

    var repeatMode: MusicPlayer.RepeatMode {
        _ = playbackModeVersion
        return .none
    }

    var repeatEnabled: Bool {
        _ = playbackModeVersion
        return true
    }

    var repeatsSingleTrack: Bool {
        false
    }

    var repeatModeTitle: String {
        "All"
    }

    func playbackOrderState(for musicPlaylistID: String) -> PlaybackOrderState {
        _ = playbackModeVersion
        return PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: musicPlaylistID)
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
        musicKitNowPlayingTrack = nil
        isMusicKitNowPlayingTrackPending = false
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        currentPlaylistID = nil
        activeSession = nil
        activeQueueEntries = []
        activeQueueIndex = nil
        activePlaylistSnapshot = nil
        prefetchedArtworkTrackID = nil
        pendingModeQueueRebuild = nil
        pendingQueueAdvanceLocalTrackID = nil
        pendingQueueAdvanceStartedAt = nil
        lastLocalPlaybackStateFlushAt = nil
        lastLocalPlaybackStateIdentity = nil
        lastLoggedPlaybackRefreshSignature = nil
        statusMessage = "Overplay data reset."
        hasRestoredLocalPlaybackState = false
        LocalPlaybackStateStore.clear(flushImmediately: true)
        PlaybackIdentityStore.clearAll(flushImmediately: true)
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
            let restoredLocalTrackID = state.localTrackID ?? localTrackID(
                matching: state.musicItemID,
                playlistID: state.playlistID,
                context: context
            )
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
            let queueEntries = try PlaybackQueueOrchestrator.orderedQueueEntries(
                from: tracks,
                playlistID: state.playlistID,
                playerID: playerID,
                startingTrackID: startingLocalTrackID,
                in: context
            )
            guard !queueEntries.isEmpty else {
                statusMessage = "Could not restore playback because the local queue is unavailable."
                return
            }
            pendingModeQueueRebuild = nil
            let materialization = materializeActiveQueue(entries: queueEntries, startingAt: startingLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(
                materialization.queueEntries,
                startingAt: materialization.startingEntry
            )
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
            updateMusicKitNowPlayingTrack()
            rebuildActivePlaylistSnapshot(context: context)
            NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
            prefetchCurrentArtworkIfNeeded(musicItemID: restoredMusicItemID, playlistID: state.playlistID)
        } catch {
            statusMessage = "Could not restore playback: \(error.localizedDescription)"
        }
    }

    func restoreLocalPlaybackDisplay(context: ModelContext) {
        guard currentTrack == nil else { return }
        guard let state = LocalPlaybackStateStore.load() else { return }

        do {
            guard let restored = try PlaybackRestorationService.displayRestoreState(from: state, in: context) else {
                return
            }

            currentPlaylistID = restored.musicPlaylistID
            currentPlaylistItem = restored.playlistItem
            currentTrack = restored.track
            elapsedSeconds = restored.elapsedSeconds
            durationSeconds = restored.durationSeconds
            isPlaying = false
            activeSession = restored.activeSession
            activeQueueEntries = []
            activeQueueIndex = nil
            statusMessage = nil
            bumpPlaybackItemMetadataVersion()
            rebuildActivePlaylistSnapshot(context: context)
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
        await startPlaylistPlayback(playlist, startingAt: nil, settings: settings, context: context)
    }

    func playPlaylist(_ playlist: PlaylistRecord, startingAt track: TrackRecord, settings: OverplaySettings, context: ModelContext) async {
        await startPlaylistPlayback(playlist, startingAt: track, settings: settings, context: context)
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    private func startPlaylistPlayback(
        _ playlist: PlaylistRecord,
        startingAt trackRecord: TrackRecord?,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        do {
            let startingTrackID = trackRecord?.id.uuidString
            let queueEntries = try PlaybackQueueOrchestrator.orderedCachedQueueEntries(
                for: playlist.musicPlaylistID,
                playerID: playerID,
                startingTrackID: startingTrackID,
                in: context
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
                outgoingSessionSettings: settings,
                context: context
            )
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
        }
    }

    private func cachedPlayableMusicTracks(for playlist: PlaylistRecord, in context: ModelContext) throws -> [Track] {
        try PlaybackQueueOrchestrator.cachedPlayableMusicTracks(for: playlist, in: context)
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

    private var activeQueueCurrentLocalTrackID: String? {
        activeQueueCurrentEntry?.localTrackID
    }

    private var activeQueueCurrentEntry: RealizedPlaybackQueueEntry? {
        guard let activeQueueIndex,
              activeQueueEntries.indices.contains(activeQueueIndex) else {
            return nil
        }

        return activeQueueEntries[activeQueueIndex]
    }

    private func updateActiveQueue(realizedEntries: [RealizedPlaybackQueueEntry], startingAt localTrackID: String?) {
        let state = PlaybackQueueCoordinator.activeQueueState(entries: realizedEntries, startingAt: localTrackID)
        activeQueueEntries = state.entries
        activeQueueIndex = state.index
    }

    private func updateActiveQueueCurrentTrackID(_ localTrackID: String?) {
        activeQueueIndex = PlaybackQueueCoordinator.updatedActiveQueueIndex(
            localTrackID: localTrackID,
            activeQueueEntries: activeQueueEntries,
            currentIndex: activeQueueIndex
        )
    }

    private func advanceActiveQueueIndex(by offset: Int) {
        activeQueueIndex = PlaybackQueueCoordinator.advancedActiveQueueIndex(
            by: offset,
            activeQueueEntries: activeQueueEntries,
            currentIndex: activeQueueIndex
        )
    }

    private func materializeActiveQueue(
        entries: [PlaybackQueueEntry],
        startingAt localTrackID: String?
    ) -> PlaybackQueueMaterialization {
        let materialization = PlaybackQueueMaterializer.materialize(entries, startingAt: localTrackID)
        updateActiveQueue(realizedEntries: materialization.realizedEntries, startingAt: localTrackID)
        return materialization
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
        outgoingSessionSettings: OverplaySettings? = nil,
        context: ModelContext
    ) async throws {
        guard !queueEntries.isEmpty else {
            statusMessage = "No playable tracks remain after local evictions."
            return
        }

        if let outgoingSessionSettings {
            await evaluateOutgoingSessionBeforePlaybackReplacement(
                settings: outgoingSessionSettings,
                context: context,
                targetPlaylistID: playlistID,
                targetLocalTrackID: localTrackID
            )
        }

        // The outgoing session has had its chance to be evaluated. Whatever
        // plays next deserves a fresh countable session — in particular a
        // track resumed from a display-restored session, which is created
        // already evaluated so relaunches can never fabricate counts.
        activeSession = nil

        warmUpTask?.cancel()
        warmUpTask = nil

        disableMusicKitPlaybackModes()
        pendingModeQueueRebuild = nil
        let materialization = materializeActiveQueue(entries: queueEntries, startingAt: localTrackID)
        player.queue = ApplicationMusicPlayer.Queue(
            materialization.queueEntries,
            startingAt: materialization.startingEntry
        )
        try await player.play()
        currentPlaylistID = playlistID
        await ArtworkCacheService.shared.touchPlaylistUsage(playlistID)
        statusMessage = nil
        rebuildActivePlaylistSnapshot(context: context)
        startMonitoring(context: context)
        await refresh(context: context)
    }

    func evaluateOutgoingSessionBeforePlaybackReplacement(
        settings: OverplaySettings,
        context: ModelContext,
        targetPlaylistID: String,
        targetLocalTrackID: String?
    ) async {
        let outgoingLocalTrackID = activeSession?.localTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID
        guard activeSession != nil || currentTrack != nil else { return }
        if currentPlaylistID == targetPlaylistID,
           let targetLocalTrackID,
           targetLocalTrackID == outgoingLocalTrackID {
            return
        }

        await evaluateActiveSession(
            settings: settings,
            context: context,
            naturalCompletion: false,
            elapsedSeconds: activeSession?.lastObservedPlaybackTime ?? elapsedSeconds,
            durationSeconds: activeSession?.durationSeconds ?? durationSeconds ?? currentTrack?.durationSeconds,
            fallbackLocalTrackID: outgoingLocalTrackID
        )
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

    func performPrimaryPlaybackAction(settings: OverplaySettings, context: ModelContext) async {
        if canControlPlayback {
            await togglePlayPause(context: context)
            return
        }

        await playCurrentOrDefault(settings: settings, context: context)
    }

    func playCurrentOrDefault(settings: OverplaySettings, context: ModelContext) async {
        if canControlPlayback {
            await play(context: context)
            return
        }

        if let restoredPlayback = try? PlaybackTrackResolver.restoredPlaybackTarget(
            currentPlaylistID: currentPlaylistID,
            currentPlaylistItem: currentPlaylistItem,
            currentLocalTrackID: nowPlayingDisplayLocalTrackID,
            currentTrack: currentTrack,
            in: context
        ) {
            await playPlaylist(
                restoredPlayback.playlist,
                startingAt: restoredPlayback.track,
                settings: settings,
                context: context
            )
            return
        }

        guard let playlist = try? PlaybackTrackResolver.defaultPlaybackPlaylist(
            settings: settings,
            in: context
        ) else {
            statusMessage = "Choose a playlist first."
            return
        }

        await playPlaylist(playlist, settings: settings, context: context)
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
        elapsedSeconds = player.playbackTime
        isPlaying = false
        if let musicItemID = currentTrack?.id {
            persistLocalPlaybackState(musicItemID: musicItemID, forceFlush: true)
        }
        updateMusicKitNowPlayingTrack()
        NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: false)
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        prepareCurrentPlaylistItemForEvaluation(context: context)
        let skippedTrackID = activeSession?.trackID ?? currentTrack?.id
        let skippedLocalTrackID = activeSession?.localTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID
        await evaluateActiveSession(
            settings: settings,
            context: context,
            naturalCompletion: false,
            fallbackLocalTrackID: skippedLocalTrackID
        )

        do {
            try await player.skipToNextEntry()
            updateMusicKitNowPlayingTrack()
            advanceActiveQueueIndex(by: 1)
            updateDisplayedTrackFromActiveQueue(context: context)
            await refresh(context: context)
        } catch {
            if let skippedTrackID,
               await handleQueueEnded(
                   lastMusicItemID: skippedTrackID,
                   lastLocalTrackID: skippedLocalTrackID,
                   context: context
               ) {
                return
            }
            statusMessage = error.localizedDescription
        }
    }

    func previous(context: ModelContext) async {
        markActiveSessionEvaluatedWithoutSkip()

        do {
            try await player.skipToPreviousEntry()
            updateMusicKitNowPlayingTrack()
            advanceActiveQueueIndex(by: -1)
            updateDisplayedTrackFromActiveQueue(context: context)
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleShuffle(context: ModelContext) async {
        await reshuffleCurrentPlaylist(context: context)
    }

    func setShuffleEnabled(_ isEnabled: Bool, context: ModelContext) async {
        guard isEnabled else {
            playbackModeVersion += 1
            return
        }
        await reshuffleCurrentPlaylist(context: context)
    }

    func reshuffleCurrentPlaylist(context: ModelContext) async {
        guard let currentPlaylistID else {
            statusMessage = "Choose a playlist first."
            return
        }

        do {
            let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: currentPlaylistID, in: context)
            let currentLocalTrackID = currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID
                ?? currentTrack.flatMap { localTrackID(matching: $0.id, context: context) }
            let orderedTrackIDs = PlaybackOrderCoordinator.reshuffle(
                playerID: playerID,
                playlistID: currentPlaylistID,
                orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items),
                avoiding: currentLocalTrackID
            )
            let queueEntries = PlaybackQueueOrchestrator.cachedQueueEntries(
                orderedTrackIDs: orderedTrackIDs,
                itemsByTrackID: inputs.items.firstValueDictionary(keyedBy: \.trackID),
                tracksByID: inputs.tracksByID
            )
            disableMusicKitPlaybackModes()
            playbackModeVersion += 1
            try await startPlayback(
                queueEntries: queueEntries,
                playlistID: currentPlaylistID,
                startingAt: queueEntries.first?.localTrackID,
                context: context
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func currentPlaylistRole(context: ModelContext) -> PlaylistRole? {
        try? currentPlaylist(in: context)?.role
    }

    func skipForwardIntent(
        settings: OverplaySettings,
        context: ModelContext,
        requiresControllableQueue: Bool = true
    ) -> PlaybackSkipForwardIntent {
        _ = playbackItemMetadataVersion
        guard currentPlaylistID != nil, currentTrack != nil else { return .standard }
        if requiresControllableQueue, !canControlPlayback {
            return .standard
        }

        let currentTrackID = activeSession?.trackID ?? currentTrack?.id
        let baseSession: TrackPlaySession?
        if let activeSession {
            baseSession = activeSession
        } else {
            baseSession = PlaybackSessionEvaluationService.bootstrapSession(
                trackID: currentTrackID,
                localTrackID: currentPlaylistItem?.trackID.uuidString ?? activeQueueCurrentLocalTrackID,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds ?? currentTrack?.durationSeconds
            )
        }
        let session = baseSession.map {
            PlaybackSessionEvaluationService.updateObservedProgress(
                $0,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds ?? currentTrack?.durationSeconds
            )
        }
        let playlist = try? currentPlaylist(in: context)
        return PlaybackSessionEvaluationService.skipForwardIntent(
            session: session,
            item: session.flatMap { playlistItemForSkipForwardIntent(session: $0, playlist: playlist, context: context) },
            playlist: playlist,
            settings: settings
        )
    }

    func displayedPlaylistItem(context: ModelContext) -> PlaylistItemRecord? {
        guard let musicItemID = currentTrack?.id,
              let playlist = try? currentPlaylist(in: context) else {
            return nil
        }

        if let item = liveCurrentPlaylistItem(in: playlist, context: context) {
            return item
        }

        return try? PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: musicItemID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        )
    }

    private func currentPlaybackTarget(context: ModelContext) -> CurrentPlaybackTarget? {
        guard let musicItemID = currentTrack?.id,
              let playlist = try? currentPlaylist(in: context) else {
            return nil
        }

        if let currentPlaylistItem = liveCurrentPlaylistItem(in: playlist, context: context) {
            return CurrentPlaybackTarget(
                musicItemID: musicItemID,
                playlist: playlist,
                item: currentPlaylistItem
            )
        }

        guard let item = try? PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: musicItemID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        ) else {
            return nil
        }

        return CurrentPlaybackTarget(
            musicItemID: musicItemID,
            playlist: playlist,
            item: item
        )
    }

    private func liveCurrentPlaylistItem(
        in playlist: PlaylistRecord,
        context: ModelContext
    ) -> PlaylistItemRecord? {
        guard let currentPlaylistItem,
              currentPlaylistItem.playlistID == playlist.id else {
            return nil
        }

        if let liveItem = try? PlaylistItemRepository.item(id: currentPlaylistItem.id, in: context),
           liveItem.playlistID == playlist.id {
            return liveItem
        }

        return currentPlaylistItem
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
                ?? currentMusicItemID.flatMap { localTrackID(matching: $0, context: context) }
            let queueEntries = try PlaybackQueueOrchestrator.orderedCachedQueueEntries(
                for: currentPlaylistID,
                playerID: playerID,
                retainedTrackID: currentLocalTrackID,
                in: context
            )
            guard !queueEntries.isEmpty else { return }
            let startingLocalTrackID = currentLocalTrackID
                ?? currentMusicItemID.flatMap { localTrackID(matching: $0, context: context) }

            disableMusicKitPlaybackModes()
            pendingModeQueueRebuild = nil
            let materialization = materializeActiveQueue(entries: queueEntries, startingAt: startingLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(
                materialization.queueEntries,
                startingAt: materialization.startingEntry
            )
            if materialization.startingEntry != nil {
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
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to keep."
            return
        }

        do {
            try TrackHealthActionService.keepCurrentTrack(
                target.item,
                playlist: target.playlist,
                protect: settings.protectKeptTracks,
                message: "Kept by user",
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
    }

    func promoteCurrent(settings: OverplaySettings, context: ModelContext) async {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked triage track to promote."
            return
        }

        do {
            _ = try await PlaylistMutationService().promote(item: target.item, in: context)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        statusMessage = "Promoted \(currentTrack?.title ?? "track") to the One True Playlist."
        await next(settings: settings, context: context)
    }

    @discardableResult
    func protectCurrentTrack(context: ModelContext, message: String = "Protected by user") -> Bool {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to protect."
            return false
        }

        do {
            try TrackHealthActionService.protectTrack(
                target.item,
                playlist: target.playlist,
                message: message,
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        return true
    }

    @discardableResult
    func toggleCurrentKeep(
        context: ModelContext,
        enabledMessage: String = "Keep turned on by user",
        disabledMessage: String = "Keep turned off by user"
    ) -> Bool {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to toggle keep."
            return false
        }

        let shouldProtect = !target.item.protected
        do {
            try TrackHealthActionService.setProtected(
                target.item,
                playlist: target.playlist,
                isProtected: shouldProtect,
                message: shouldProtect ? enabledMessage : disabledMessage,
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        return true
    }

    @discardableResult
    func resetCurrentSkipCount(context: ModelContext, message: String = "Skip count reset by user") -> Bool {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to reset."
            return false
        }

        do {
            try TrackHealthActionService.resetSkipCount(
                target.item,
                playlist: target.playlist,
                message: message,
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        return true
    }

    func resetAllLocalStats(context: ModelContext) throws {
        try PlaylistItemRepository.resetAllStats(in: context)
        refreshCurrentPlaybackMetadata(context: context)
        rebuildActivePlaylistSnapshot(context: context)
    }

    func restoreTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord?,
        context: ModelContext
    ) throws {
        try TrackHealthActionService.restoreTrack(item, playlist: playlist, in: context)
        refreshCurrentPlaybackMetadata(context: context)
        rebuildActivePlaylistSnapshot(context: context)
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to evict."
            return
        }

        do {
            try TrackHealthActionService.evictTrack(
                target.item,
                playlist: target.playlist,
                message: "Evicted manually",
                in: context
            )
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        currentPlaylistItem = target.item
        rebuildActivePlaylistSnapshot(context: context)
        await removeEvictedItemFromPlaylist(target.item, playlist: target.playlist, context: context)
        await next(settings: settings, context: context)
    }

    private func refresh(context: ModelContext) async {
        let oldTrackID = activeSession?.trackID
        let oldLocalTrackID = activeSession?.localTrackID
        let oldCurrentItemLocalTrackID = currentPlaylistItem?.trackID.uuidString
        let oldActiveQueueLocalTrackID = activeQueueCurrentLocalTrackID
        updateMusicKitNowPlayingTrack()
        let identity = resolvedCurrentPlaybackIdentity(context: context)
        let newTrackID = identity?.musicItemID
        let newLocalTrackID = identity?.localTrackID
        let currentPlaybackTime = player.playbackTime
        elapsedSeconds = currentPlaybackTime
        isPlaying = player.state.playbackStatus == .playing

        if let oldTrackID, newTrackID == nil, !isRestartingQueue {
            if let settings = try? SettingsRepository.settings(in: context) {
                await evaluateActiveSession(settings: settings, context: context, naturalCompletion: true)
            }

            if await handleQueueEnded(
                lastMusicItemID: oldTrackID,
                lastLocalTrackID: oldLocalTrackID,
                context: context
            ) {
                return
            }
        }

        let didChangeTrack = playbackIdentityDidChange(
            oldTrackID: oldTrackID,
            oldLocalTrackID: oldLocalTrackID,
            newTrackID: newTrackID,
            newLocalTrackID: newLocalTrackID
        )

        if didChangeTrack, let settings = try? SettingsRepository.settings(in: context) {
            await evaluateActiveSession(
                settings: settings,
                context: context,
                naturalCompletion: false,
                elapsedSeconds: activeSession?.lastObservedPlaybackTime,
                durationSeconds: activeSession?.durationSeconds,
                fallbackLocalTrackID: oldLocalTrackID
                    ?? oldCurrentItemLocalTrackID
                    ?? oldActiveQueueLocalTrackID
            )
            elapsedSeconds = currentPlaybackTime
        }

        if didChangeTrack, let identity {
            applyResolvedPlaybackIdentity(identity, context: context)
        }

        if let identity {
            if !didChangeTrack {
                applyResolvedPlaybackIdentity(identity, context: context)
            }
            durationSeconds = currentTrack?.durationSeconds
            prefetchCurrentArtworkIfNeeded(musicItemID: identity.musicItemID, playlistID: currentPlaylistID)

            if let activeSession, session(activeSession, matches: identity) {
                self.activeSession = PlaybackSessionEvaluationService.updateObservedProgress(
                    activeSession,
                    elapsedSeconds: elapsedSeconds,
                    durationSeconds: durationSeconds
                )
            } else {
                activeSession = PlaybackSessionEvaluationService.bootstrapSession(
                    trackID: identity.musicItemID,
                    localTrackID: identity.localTrackID,
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
            activeQueueEntries = []
            activeQueueIndex = nil
            currentPlaylistID = nil
            activePlaylistSnapshot = nil
            prefetchedArtworkTrackID = nil
        }

        logPlaybackRefreshIfNeeded(identity: identity)
        NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
        if currentPlaylistID == nil {
            activePlaylistSnapshot = nil
        } else {
            updateActivePlaylistSnapshotCurrentRow()
        }

        if let newTrackID {
            persistLocalPlaybackState(musicItemID: newTrackID, localTrackID: newLocalTrackID)
        }
    }

    private func applyResolvedPlaybackIdentity(_ identity: CurrentPlaybackIdentity, context: ModelContext) {
        resolveCurrentPlaylistItem(for: identity, context: context)
        if let localTrackID = identity.localTrackID {
            updateActiveQueueCurrentTrackID(localTrackID)
        }
        syncPlaybackMetadata(
            for: identity.musicItemID,
            trustedPlaylistItem: trustedPlaylistItem(for: identity),
            context: context
        )
        persistResolvedPlaybackIdentity(identity)
    }

    private func trustedPlaylistItem(for identity: CurrentPlaybackIdentity) -> PlaylistItemRecord? {
        if identity.isQueueCorrelated {
            return currentPlaylistItem
        }

        guard identity.source == "activeSession" else {
            return nil
        }

        if let playlistItemID = identity.playlistItemID,
           currentPlaylistItem?.id == playlistItemID {
            return currentPlaylistItem
        }

        if let localTrackID = identity.localTrackID,
           currentPlaylistItem?.trackID.uuidString == localTrackID {
            return currentPlaylistItem
        }

        return nil
    }

    private func playbackIdentityDidChange(
        oldTrackID: String?,
        oldLocalTrackID: String?,
        newTrackID: String?,
        newLocalTrackID: String?
    ) -> Bool {
        guard let oldTrackID, let newTrackID else { return false }
        if let oldLocalTrackID, let newLocalTrackID {
            return oldLocalTrackID != newLocalTrackID
        }

        return oldTrackID != newTrackID
    }

    private func session(_ session: TrackPlaySession, matches identity: CurrentPlaybackIdentity) -> Bool {
        if let sessionLocalTrackID = session.localTrackID,
           let identityLocalTrackID = identity.localTrackID {
            return sessionLocalTrackID == identityLocalTrackID
        }

        return session.trackID == identity.musicItemID
    }

    private func evaluatePlaythroughIfNeeded(context: ModelContext) {
        guard let settings = try? SettingsRepository.settings(in: context) else { return }
        do {
            let outcome = try PlaybackSessionEvaluationService.evaluatePlaythroughIfNeeded(
                session: activeSession,
                currentPlaylistItem: currentPlaylistItem,
                playlist: currentPlaylist(in: context),
                settings: settings,
                context: context,
                fallbackLocalTrackID: currentPlaylistItem?.trackID.uuidString
                    ?? activeQueueCurrentLocalTrackID
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

    private func evaluateActiveSession(
        settings: OverplaySettings,
        context: ModelContext,
        naturalCompletion: Bool,
        elapsedSeconds observedElapsedSeconds: Double? = nil,
        durationSeconds observedDurationSeconds: Double? = nil,
        fallbackLocalTrackID: String? = nil
    ) async {
        elapsedSeconds = observedElapsedSeconds ?? player.playbackTime
        prepareCurrentPlaylistItemForEvaluation(context: context)

        do {
            let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
                activeSession: activeSession,
                currentTrackID: currentTrack?.id,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: observedDurationSeconds ?? durationSeconds ?? currentTrack?.durationSeconds,
                currentPlaylistItem: currentPlaylistItem,
                playlist: currentPlaylist(in: context),
                settings: settings,
                naturalCompletion: naturalCompletion,
                context: context,
                fallbackLocalTrackID: fallbackLocalTrackID
                    ?? currentPlaylistItem?.trackID.uuidString
                    ?? activeQueueCurrentLocalTrackID
            )
            applyEvaluationOutcome(outcome, context: context)

            if let outcome, outcome.evictedDuringEvaluation, let item = outcome.item, let playlist = outcome.playlist {
                await removeEvictedItemFromPlaylist(item, playlist: playlist, context: context)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyEvaluationOutcome(_ outcome: PlaybackSessionEvaluationService.EvaluationOutcome?, context: ModelContext) {
        guard let outcome else { return }
        activeSession = outcome.session
        let shouldApplyToDisplayedPlayback = evaluationOutcomeMatchesDisplayedPlayback(outcome)
        let shouldRefreshActivePlaylist = evaluationOutcomeAffectsActivePlaylist(outcome)
        if let item = outcome.item, shouldApplyToDisplayedPlayback {
            currentPlaylistItem = item
            bumpPlaybackItemMetadataVersion()
        } else if let item = outcome.item {
            TrackMetadataDiagnostics.log(
                "suppressed stale evaluation outcome trackID=\(outcome.session.trackID) item=\(TrackMetadataDiagnostics.describe(item)) currentItem=\(TrackMetadataDiagnostics.describe(currentPlaylistItem)) currentTrack=\(TrackMetadataDiagnostics.describe(currentTrack))"
            )
        }
        if outcome.shouldSyncPlaybackMetadata, shouldApplyToDisplayedPlayback {
            syncPlaybackMetadata(
                for: outcome.session.trackID,
                trustedPlaylistItem: outcome.item,
                context: context
            )
        }
        if shouldRefreshActivePlaylist {
            rebuildActivePlaylistSnapshot(context: context)
        }
    }

    func evaluationOutcomeAffectsActivePlaylist(_ outcome: PlaybackSessionEvaluationService.EvaluationOutcome) -> Bool {
        guard let currentPlaylistID,
              let outcomePlaylistID = outcome.playlist?.musicPlaylistID else {
            return false
        }

        return outcome.item != nil && outcomePlaylistID == currentPlaylistID
    }

    func evaluationOutcomeMatchesDisplayedPlayback(_ outcome: PlaybackSessionEvaluationService.EvaluationOutcome) -> Bool {
        if let outcomeItemID = outcome.item?.id,
           let currentItemID = currentPlaylistItem?.id {
            return outcomeItemID == currentItemID
        }

        if let sessionLocalTrackID = outcome.session.localTrackID {
            if let currentItem = currentPlaylistItem,
               sessionLocalTrackID == currentItem.trackID.uuidString {
                return true
            }

            if let activeQueueCurrentLocalTrackID {
                return sessionLocalTrackID == activeQueueCurrentLocalTrackID
            }
        }

        return outcome.session.trackID == currentTrack?.id
    }

    private func prepareCurrentPlaylistItemForEvaluation(context: ModelContext) {
        guard currentPlaylistItem == nil else { return }

        if let localTrackID = activeQueueCurrentLocalTrackID,
           let item = try? playlistItem(localTrackID: localTrackID, context: context) {
            currentPlaylistItem = item
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

    private func playlistItem(id: UUID, context: ModelContext) throws -> PlaylistItemRecord? {
        guard let playlist = try currentPlaylist(in: context),
              let item = try PlaylistItemRepository.item(id: id, in: context),
              item.playlistID == playlist.id else {
            return nil
        }

        return item
    }

    private func localTrackID(
        matching musicItemID: String,
        playlistID: String? = nil,
        context: ModelContext
    ) -> String? {
        if let playlistID = playlistID ?? currentPlaylistID {
            do {
                if let scopedLocalTrackID = try PlaybackQueueOrchestrator.localTrackID(
                    matching: musicItemID,
                    playlistID: playlistID,
                    in: context
                ) {
                    return scopedLocalTrackID
                }

                if let aliasLocalTrackID = try localTrackIDMatchingAlias(
                    musicItemID,
                    playlistID: playlistID,
                    context: context
                ) {
                    return aliasLocalTrackID
                }
            } catch {
                if let fallbackLocalTrackID = try? PlaybackQueueCoordinator.localTrackID(matching: musicItemID, context: context) {
                    return fallbackLocalTrackID
                }
            }
        }

        return try? PlaybackQueueCoordinator.localTrackID(matching: musicItemID, context: context)
    }

    private func localTrackIDMatchingAlias(
        _ musicItemID: String,
        playlistID: String,
        context: ModelContext
    ) throws -> String? {
        let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: playlistID, in: context)
        let candidateLocalTrackIDs = Set(inputs.items.map { $0.trackID.uuidString })
        return PlaybackIdentityStore.localTrackID(
            matching: musicItemID,
            playerID: playerID,
            musicPlaylistID: playlistID,
            candidateLocalTrackIDs: candidateLocalTrackIDs
        )
    }

    private func recordTrustedRuntimeAlias(
        _ musicItemID: String,
        for realizedEntry: RealizedPlaybackQueueEntry,
        context: ModelContext
    ) {
        guard let currentPlaylistID else { return }
        if let trackID = UUID(uuidString: realizedEntry.localTrackID),
           let track = try? TrackRecordRepository.track(id: trackID, in: context),
           PlaybackQueueBuilder.musicItemIDs(for: track).contains(musicItemID) {
            return
        }

        PlaybackIdentityStore.recordAlias(
            musicItemID,
            playerID: playerID,
            musicPlaylistID: currentPlaylistID,
            localTrackID: realizedEntry.localTrackID
        )
    }

    private func currentPlaybackTrack(
        musicItemID: String,
        playlistItem: PlaylistItemRecord?,
        trustPlaylistItem: Bool = false,
        context: ModelContext
    ) -> CurrentPlaybackTrack? {
        PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: musicItemID,
            playlistItem: playlistItem,
            musicPlaylistID: currentPlaylistID,
            queueItem: player.queue.currentEntry?.item,
            trustPlaylistItem: trustPlaylistItem,
            in: context
        )
    }

    private func resolveCurrentPlaylistItem(for identity: CurrentPlaybackIdentity, context: ModelContext) {
        if let playlistItemID = identity.playlistItemID,
           let matched = try? playlistItem(id: playlistItemID, context: context) {
            currentPlaylistItem = matched
            return
        }

        if let localTrackID = identity.localTrackID,
           let matched = try? playlistItem(localTrackID: localTrackID, context: context) {
            currentPlaylistItem = matched
            return
        }

        if let matched = try? playlistItem(matching: identity.musicItemID, context: context) {
            currentPlaylistItem = matched
            return
        }

        if let currentPlaylistItem,
           (try? PlaybackSessionSupport.itemMatchesMusicItemID(
               currentPlaylistItem,
               musicItemID: identity.musicItemID,
               in: context
           )) == true {
            return
        }

        currentPlaylistItem = nil
    }

    private func resolvedCurrentPlaybackIdentity(context: ModelContext) -> CurrentPlaybackIdentity? {
        if let pendingIdentity = pendingQueueAdvanceIdentity(context: context) {
            return pendingIdentity
        }

        if let queueEntry = player.queue.currentEntry {
            let queueReportedTrackID = queueEntry.item?.id.rawValue
            if let realizedEntry = activeQueueEntries.first(where: { $0.queueEntryID == queueEntry.id }) {
                clearPendingQueueAdvanceIfNeeded(matchedLocalTrackID: realizedEntry.localTrackID)
                updateActiveQueueCurrentTrackID(realizedEntry.localTrackID)
                let musicItemID = queueReportedTrackID ?? realizedEntry.queuedMusicItemID
                recordTrustedRuntimeAlias(musicItemID, for: realizedEntry, context: context)
                return CurrentPlaybackIdentity(
                    musicItemID: musicItemID,
                    localTrackID: realizedEntry.localTrackID,
                    playlistItemID: realizedEntry.playlistItemID,
                    isQueueCorrelated: true,
                    source: "player.queue.currentEntry.realized"
                )
            }

            if let queueReportedTrackID {
                let localTrackID = localTrackID(matching: queueReportedTrackID, context: context)
                if let localTrackID {
                    clearPendingQueueAdvanceIfNeeded(matchedLocalTrackID: localTrackID)
                    updateActiveQueueCurrentTrackID(localTrackID)
                    return CurrentPlaybackIdentity(
                        musicItemID: queueReportedTrackID,
                        localTrackID: localTrackID,
                        playlistItemID: nil,
                        isQueueCorrelated: false,
                        source: "player.queue.currentEntry.reported"
                    )
                }

                // Only use the active queue fallback when MusicKit's reported
                // item still names the same track. If MusicKit reports a
                // different unresolved item, surface that item so external
                // navigation cannot leave the UI stuck on the old local row.
                if let activeQueueCurrentEntry,
                   PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
                       queueReportedTrackID: queueReportedTrackID,
                       activeQueueMusicItemID: activeQueueCurrentEntry.queuedMusicItemID,
                       isModeQueueRebuildPending: pendingModeQueueRebuild != nil
                   ) {
                    return CurrentPlaybackIdentity(
                        musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
                        localTrackID: activeQueueCurrentEntry.localTrackID,
                        playlistItemID: activeQueueCurrentEntry.playlistItemID,
                        isQueueCorrelated: true,
                        source: "player.queue.currentEntry.unresolved.activeQueueFallback"
                    )
                }

                return CurrentPlaybackIdentity(
                    musicItemID: queueReportedTrackID,
                    localTrackID: nil,
                    playlistItemID: nil,
                    isQueueCorrelated: false,
                    source: "player.queue.currentEntry.unresolved"
                )
            }
        }

        if let activeQueueCurrentEntry, pendingModeQueueRebuild == nil {
            return CurrentPlaybackIdentity(
                musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
                localTrackID: activeQueueCurrentEntry.localTrackID,
                playlistItemID: activeQueueCurrentEntry.playlistItemID,
                isQueueCorrelated: true,
                source: "activeQueueCurrentEntry"
            )
        }

        if let activeSession {
            return CurrentPlaybackIdentity(
                musicItemID: activeSession.trackID,
                localTrackID: activeSession.localTrackID,
                playlistItemID: currentPlaylistItem?.id,
                isQueueCorrelated: false,
                source: "activeSession"
            )
        }

        if let currentTrack {
            return CurrentPlaybackIdentity(
                musicItemID: currentTrack.id,
                localTrackID: currentPlaylistItem?.trackID.uuidString,
                playlistItemID: currentPlaylistItem?.id,
                isQueueCorrelated: false,
                source: "currentTrackSnapshot"
            )
        }

        return nil
    }

    private func pendingQueueAdvanceIdentity(context: ModelContext) -> CurrentPlaybackIdentity? {
        guard let pendingQueueAdvanceLocalTrackID,
              let pendingQueueAdvanceStartedAt else {
            return nil
        }

        guard Date.now.timeIntervalSince(pendingQueueAdvanceStartedAt) < 2 else {
            clearPendingQueueAdvance()
            return nil
        }

        guard let activeQueueCurrentEntry,
              activeQueueCurrentEntry.localTrackID == pendingQueueAdvanceLocalTrackID else {
            clearPendingQueueAdvance()
            return nil
        }

        if let queueEntry = player.queue.currentEntry {
            if let realizedEntry = activeQueueEntries.first(where: { $0.queueEntryID == queueEntry.id }),
               realizedEntry.localTrackID == pendingQueueAdvanceLocalTrackID {
                clearPendingQueueAdvance()
                return nil
            }

            if let queueReportedTrackID = queueEntry.item?.id.rawValue,
               let reportedLocalTrackID = localTrackID(matching: queueReportedTrackID, context: context),
               reportedLocalTrackID == pendingQueueAdvanceLocalTrackID {
                clearPendingQueueAdvance()
                return nil
            }
        }

        return CurrentPlaybackIdentity(
            musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
            localTrackID: activeQueueCurrentEntry.localTrackID,
            playlistItemID: activeQueueCurrentEntry.playlistItemID,
            isQueueCorrelated: true,
            source: "pendingQueueAdvance"
        )
    }

    private func clearPendingQueueAdvanceIfNeeded(matchedLocalTrackID: String) {
        guard pendingQueueAdvanceLocalTrackID == matchedLocalTrackID else { return }
        clearPendingQueueAdvance()
    }

    private func clearPendingQueueAdvance() {
        pendingQueueAdvanceLocalTrackID = nil
        pendingQueueAdvanceStartedAt = nil
    }

    private func logPlaybackRefreshIfNeeded(identity: CurrentPlaybackIdentity?) {
        let signature = [
            "identityMusicID=\(identity?.musicItemID ?? "nil")",
            "identityLocalID=\(identity?.localTrackID ?? "nil")",
            "identityItemID=\(identity?.playlistItemID?.uuidString ?? "nil")",
            "identitySource=\(identity?.source ?? "nil")",
            "currentTrackID=\(currentTrack?.id ?? "nil")",
            "currentItemID=\(currentPlaylistItem?.id.uuidString ?? "nil")",
            "activeQueueIndex=\(activeQueueIndex.map(String.init) ?? "nil")",
            "activeSessionTrackID=\(activeSession?.trackID ?? "nil")",
            "activeSessionLocalID=\(activeSession?.localTrackID ?? "nil")"
        ].joined(separator: " ")

        guard signature != lastLoggedPlaybackRefreshSignature else { return }
        lastLoggedPlaybackRefreshSignature = signature
        TrackMetadataDiagnostics.log("playback refresh identity \(signature)")
    }

    private func playlistItemForSkipForwardIntent(
        session: TrackPlaySession,
        playlist: PlaylistRecord?,
        context: ModelContext
    ) -> PlaylistItemRecord? {
        guard let playlist else { return nil }

        if let localTrackID = session.localTrackID ?? activeQueueCurrentLocalTrackID,
           let item = try? playlistItem(localTrackID: localTrackID, context: context),
           item.playlistID == playlist.id {
            return item
        }

        if let item = try? PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: session.trackID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        ) {
            return item
        }

        if let localTrackID = activeQueueCurrentLocalTrackID,
           let item = try? playlistItem(localTrackID: localTrackID, context: context),
           item.playlistID == playlist.id,
           (try? PlaybackSessionSupport.itemMatchesMusicItemID(
               item,
               musicItemID: session.trackID,
               in: context
           )) == true {
            return item
        }

        return nil
    }

    private func syncPlaybackMetadata(
        for musicItemID: String,
        trustedPlaylistItem: PlaylistItemRecord? = nil,
        context: ModelContext
    ) {
        let update = PlaybackTrackMetadataSync.metadataUpdate(
            for: musicItemID,
            currentTrack: currentTrack,
            currentPlaylistItem: currentPlaylistItem,
            trustedPlaylistItem: trustedPlaylistItem,
            currentPlaylistID: currentPlaylistID,
            queueItem: player.queue.currentEntry?.item,
            in: context
        )
        if currentPlaylistItem?.id != update.playlistItem?.id {
            currentPlaylistItem = update.playlistItem
        }

        if let track = update.track {
            if currentTrack != track {
                currentTrack = track
                bumpPlaybackItemMetadataVersion()
            }
        } else if currentTrack?.id != musicItemID {
            currentTrack = nil
            bumpPlaybackItemMetadataVersion()
        }
    }

    private func updateMusicKitNowPlayingTrack() {
        guard let currentEntry = player.queue.currentEntry else {
            if musicKitNowPlayingTrack != nil {
                musicKitNowPlayingTrack = nil
            }
            if isMusicKitNowPlayingTrackPending {
                isMusicKitNowPlayingTrackPending = false
            }
            return
        }

        guard let track = PlaybackTrackResolver.currentPlaybackTrack(
            from: currentEntry.item,
            playlistID: currentPlaylistID
        ) else {
            if !isMusicKitNowPlayingTrackPending {
                isMusicKitNowPlayingTrackPending = true
            }
            return
        }

        if musicKitNowPlayingTrack != track {
            musicKitNowPlayingTrack = track
        }
        if isMusicKitNowPlayingTrackPending {
            isMusicKitNowPlayingTrackPending = false
        }
    }

    private func refreshCurrentPlaybackMetadata(context: ModelContext) {
        guard let musicItemID = currentTrack?.id else { return }
        syncPlaybackMetadata(for: musicItemID, context: context)
    }

    private func markActiveSessionEvaluatedWithoutSkip() {
        activeSession = PlaybackSessionEvaluationService.markEvaluatedWithoutSkip(
            activeSession: activeSession,
            currentTrackID: currentTrack?.id,
            localTrackID: currentPlaylistItem?.trackID.uuidString ?? activeQueueCurrentLocalTrackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds ?? currentTrack?.durationSeconds
        )
    }

    private func bumpPlaybackItemMetadataVersion() {
        playbackItemMetadataVersion += 1
    }

    private func updateDisplayedTrackFromActiveQueue(context: ModelContext) {
        guard let activeQueueCurrentEntry,
              let localTrackID = activeQueueCurrentLocalTrackID,
              let item = try? playlistItem(localTrackID: localTrackID, context: context),
              let track = try? TrackRecordRepository.track(id: item.trackID, in: context) else {
            return
        }

        currentPlaylistItem = item
        currentTrack = CurrentPlaybackTrack(track, musicItemID: activeQueueCurrentEntry.queuedMusicItemID, item: item)
        durationSeconds = currentTrack?.durationSeconds
        pendingQueueAdvanceLocalTrackID = activeQueueCurrentEntry.localTrackID
        pendingQueueAdvanceStartedAt = .now
        bumpPlaybackItemMetadataVersion()
        updateActivePlaylistSnapshotCurrentRow()
        NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
        persistLocalPlaybackState(
            musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
            localTrackID: activeQueueCurrentEntry.localTrackID
        )
    }

    private func stagePendingModeQueueRebuild(after currentLocalTrackID: String, context: ModelContext) async {
        guard let currentPlaylistID,
              let currentQueueEntry = player.queue.currentEntry else {
            return
        }

        do {
            let queueEntries = try PlaybackQueueOrchestrator.orderedCachedQueueEntries(
                for: currentPlaylistID,
                playerID: playerID,
                retainedTrackID: currentLocalTrackID,
                in: context
            )
            let transitionEntries = PlaybackQueueCoordinator.transitionEntries(
                from: queueEntries,
                startingAt: currentLocalTrackID
            )
            let upcomingEntries = Array(transitionEntries.dropFirst())
            guard !upcomingEntries.isEmpty else { return }

            let upcomingTracks = upcomingEntries.map(\.musicTrack)
            try await player.queue.insert(upcomingTracks, position: .afterCurrentEntry)

            if let currentRealizedEntry = currentRealizedQueueEntry(
                queueEntryID: currentQueueEntry.id,
                localTrackID: currentLocalTrackID,
                context: context
            ) {
                activeQueueEntries = [currentRealizedEntry]
                activeQueueIndex = 0
            }
        } catch {
            TrackMetadataDiagnostics.log(
                "pending mode queue staging failed currentLocalTrackID=\(currentLocalTrackID) error=\(error.localizedDescription)"
            )
        }
    }

    private func currentRealizedQueueEntry(
        queueEntryID: String,
        localTrackID: String,
        context: ModelContext
    ) -> RealizedPlaybackQueueEntry? {
        guard let item = try? playlistItem(localTrackID: localTrackID, context: context) else {
            return nil
        }

        guard let musicItemID = player.queue.currentEntry?.item?.id.rawValue
            ?? currentTrack?.id
            ?? activeQueueCurrentEntry?.queuedMusicItemID else {
            return nil
        }

        return RealizedPlaybackQueueEntry(
            queueEntryID: queueEntryID,
            playlistItemID: item.id,
            localTrackID: localTrackID,
            queuedMusicItemID: musicItemID
        )
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
        persistLocalPlaybackState(musicItemID: musicItemID, localTrackID: nil, forceFlush: false)
    }

    private func persistLocalPlaybackState(musicItemID: String, forceFlush: Bool) {
        persistLocalPlaybackState(musicItemID: musicItemID, localTrackID: nil, forceFlush: forceFlush)
    }

    private func persistLocalPlaybackState(musicItemID: String, localTrackID: String?) {
        persistLocalPlaybackState(musicItemID: musicItemID, localTrackID: localTrackID, forceFlush: false)
    }

    private func persistLocalPlaybackState(
        musicItemID: String,
        localTrackID explicitLocalTrackID: String?,
        forceFlush: Bool
    ) {
        guard let currentPlaylistID else {
            return
        }

        let now = Date()
        let localTrackID = explicitLocalTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID
        let identity = LocalPlaybackStateIdentity(
            playlistID: currentPlaylistID,
            musicItemID: musicItemID,
            localTrackID: localTrackID
        )
        let shouldFlush = LocalPlaybackStateFlushPolicy.shouldFlush(
            now: now,
            lastFlushAt: lastLocalPlaybackStateFlushAt,
            isPlaying: isPlaying,
            didChangePlaybackIdentity: identity != lastLocalPlaybackStateIdentity,
            force: forceFlush
        )

        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: currentPlaylistID,
            musicItemID: musicItemID,
            elapsedSeconds: elapsedSeconds,
            wasPlaying: isPlaying,
            updatedAt: now,
            localTrackID: localTrackID
        ), flushImmediately: shouldFlush)

        lastLocalPlaybackStateIdentity = identity
        if shouldFlush {
            lastLocalPlaybackStateFlushAt = now
        }
    }

    private func persistResolvedPlaybackIdentity(_ identity: CurrentPlaybackIdentity) {
        guard currentTrack?.id == identity.musicItemID else { return }

        persistLocalPlaybackState(
            musicItemID: identity.musicItemID,
            localTrackID: identity.localTrackID ?? currentPlaylistItem?.trackID.uuidString
        )
    }

    private func handleQueueEnded(
        lastMusicItemID: String,
        lastLocalTrackID: String? = nil,
        context: ModelContext
    ) async -> Bool {
        guard let currentPlaylistID,
              (try? currentPlaylist(in: context)) != nil,
              !isRestartingQueue else {
            return false
        }

        isRestartingQueue = true
        defer { isRestartingQueue = false }

        do {
            let queueEntries = try PlaybackQueueOrchestrator.reshuffledQueueEntries(
                playlistID: currentPlaylistID,
                playerID: playerID,
                avoiding: lastLocalTrackID ?? localTrackID(
                    matching: lastMusicItemID,
                    playlistID: currentPlaylistID,
                    context: context
                ),
                in: context
            )
            playbackModeVersion += 1
            guard !queueEntries.isEmpty else { return false }

            disableMusicKitPlaybackModes()
            let startingLocalTrackID = queueEntries.first?.localTrackID
            let materialization = materializeActiveQueue(entries: queueEntries, startingAt: startingLocalTrackID)
            player.queue = ApplicationMusicPlayer.Queue(
                materialization.queueEntries,
                startingAt: materialization.startingEntry
            )
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
        _ = lastMusicItemID
        _ = movingForward
        _ = context
        pendingModeQueueRebuild = nil
        return false
    }

    func reconcileStoredOrder(for playlist: PlaylistRecord, context: ModelContext) {
        let currentLocalTrackID = currentPlaylistID == playlist.musicPlaylistID ? currentPlaylistItem?.trackID.uuidString : nil
        do {
            _ = try PlaylistItemRepository.mergeDuplicateItems(in: context)
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: items)
            let previousState = PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: playlist.musicPlaylistID)
            let playableOrder = PlaybackOrderEngine.normalOrder(for: orderTracks, includeUnplayableTrackID: currentLocalTrackID)
            let reconciledOrder: [String]
            if currentPlaylistID == playlist.musicPlaylistID, !previousState.orderedTrackIDs.isEmpty {
                let existingSet = Set(previousState.orderedTrackIDs)
                reconciledOrder = previousState.orderedTrackIDs + playableOrder.filter { !existingSet.contains($0) }
            } else {
                reconciledOrder = PlaybackOrderEngine.reconciledOrder(
                    storedOrder: previousState.orderedTrackIDs,
                    tracks: orderTracks,
                    includeUnplayableTrackID: currentLocalTrackID
                )
            }
            if previousState.orderedTrackIDs != reconciledOrder {
                PlaybackOrderStore.save(
                    PlaybackOrderState(
                        playerID: playerID,
                        musicPlaylistID: playlist.musicPlaylistID,
                        orderedTrackIDs: reconciledOrder
                    ),
                    flushImmediately: true
                )
                playbackModeVersion += 1
                let previousSet = Set(previousState.orderedTrackIDs)
                let appendedIDs = reconciledOrder.filter { !previousSet.contains($0) }
                if currentPlaylistID == playlist.musicPlaylistID, !appendedIDs.isEmpty {
                    Task { @MainActor [weak self] in
                        await self?.appendLiveQueueEntries(
                            localTrackIDs: appendedIDs,
                            playlistID: playlist.musicPlaylistID,
                            context: context
                        )
                    }
                }
            }
            if currentPlaylistID == playlist.musicPlaylistID {
                rebuildActivePlaylistSnapshot(context: context)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func appendLiveQueueEntries(
        localTrackIDs: [String],
        playlistID: String,
        context: ModelContext
    ) async {
        guard currentPlaylistID == playlistID,
              !localTrackIDs.isEmpty else {
            return
        }

        do {
            let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: playlistID, in: context)
            let entries = PlaybackQueueOrchestrator.cachedQueueEntries(
                orderedTrackIDs: localTrackIDs,
                itemsByTrackID: inputs.items.firstValueDictionary(keyedBy: \.trackID),
                tracksByID: inputs.tracksByID
            )
            guard !entries.isEmpty else { return }
            try await player.queue.insert(entries.map(\.musicTrack), position: .tail)
        } catch {
            statusMessage = "Added tracks locally, but updating the live queue failed: \(error.localizedDescription)"
        }
    }

    private func reconcileCurrentPlaybackOrder(context: ModelContext) {
        guard currentPlaylistID != nil,
              let playlist = try? currentPlaylist(in: context) else {
            return
        }

        reconcileStoredOrder(for: playlist, context: context)
    }

    private func rebuildActivePlaylistSnapshot(context: ModelContext) {
        guard let currentPlaylistID,
              let playlist = try? currentPlaylist(in: context) else {
            activePlaylistSnapshot = nil
            return
        }

        do {
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
            activePlaylistSnapshot = ActivePlaylistSnapshot(
                playlist: playlist,
                items: items,
                tracks: tracks,
                playbackOrderState: PlaybackOrderStore.state(
                    playerID: playerID,
                    musicPlaylistID: currentPlaylistID
                ),
                currentPlaylistItemID: currentPlaylistItem?.id,
                currentLocalTrackID: nowPlayingDisplayLocalTrackID,
                currentMusicItemID: nowPlayingDisplayTrack?.id ?? currentTrack?.id
            )
        } catch {
            statusMessage = "Playback is active, but refreshing the visible playlist failed: \(error.localizedDescription)"
        }
    }

    private func updateActivePlaylistSnapshotCurrentRow() {
        guard let activePlaylistSnapshot,
              activePlaylistSnapshot.musicPlaylistID == currentPlaylistID else {
            return
        }

        self.activePlaylistSnapshot = activePlaylistSnapshot.updatingCurrentRow(
            currentPlaylistItemID: currentPlaylistItem?.id,
            currentLocalTrackID: nowPlayingDisplayLocalTrackID,
            currentMusicItemID: nowPlayingDisplayTrack?.id ?? currentTrack?.id
        )
    }
}
