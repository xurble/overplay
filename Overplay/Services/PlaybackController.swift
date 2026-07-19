import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackController {
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
    var currentPlaylistScope: PlaylistPlaybackScope = .active
    var activePlaylistSnapshot: ActivePlaylistSnapshot?
    var statusMessage: String?
    /// True while streaming delivery is failing (mid-track stall, player
    /// interruption, or a restart the player refused). Cleared by witnessed
    /// playback progress or a successful user-initiated play. CarPlay
    /// watches this to surface an alert — statusMessage renders only in the
    /// iPhone/iPad Now Playing views.
    private(set) var isDeliveryStalled = false
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
    @ObservationIgnored private var pendingQueueAdvanceLocalTrackID: String?
    @ObservationIgnored private var pendingQueueAdvanceFromLocalTrackID: String?
    @ObservationIgnored private var pendingQueueAdvanceStartedAt: Date?
    @ObservationIgnored private var isPerformingTransition = false
    @ObservationIgnored private var lastLocalPlaybackStateFlushAt: Date?
    @ObservationIgnored private var lastLocalPlaybackStateIdentity: LocalPlaybackStateIdentity?
    @ObservationIgnored private var lastLoggedPlaybackRefreshSignature: String?
    @ObservationIgnored private var didLogQueueEndWithoutRestart = false
    @ObservationIgnored private var deliveryStallState = PlaybackDeliveryStallPolicy.State()
    @ObservationIgnored private var deliveryRecoveryAttempts = 0
    @ObservationIgnored private var isAttemptingDeliveryRecovery = false
    /// True while the user's last playback command was play-like. Gates
    /// stall auto-recovery so it can never auto-play after an intended stop.
    @ObservationIgnored private var playbackIntended = false
    @ObservationIgnored private var monitorIdleSince: Date?
    /// The settings row is a live singleton model object, so a cached
    /// reference reflects value changes; it only needs replacing after a
    /// database reset deletes the row.
    @ObservationIgnored private var cachedSettings: OverplaySettings?
    /// Known music item IDs of the current track, cached per local track ID
    /// — the 1 Hz refresh consults these once or twice per tick.
    @ObservationIgnored private var knownMusicItemIDsCache: (localTrackID: UUID, ids: Set<String>)?
    /// Music item IDs that failed to resolve to a local track — each miss
    /// costs a full TrackRecord scan, so misses are remembered until the
    /// next metadata change could heal them.
    @ObservationIgnored private var unresolvableMusicItemIDs: Set<String> = []
    @ObservationIgnored var isNetworkReachable: () -> Bool = { NetworkReachabilityMonitor.shared.isReachable }

    static let deliveryStallMessage =
        "Playback stalled — check your network connection. Overplay will retry when the connection returns."
    static let playbackStoppedMessage =
        "Playback stopped before the track finished — possibly a connection problem. Press play to resume."

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

    func playbackOrderState(
        for musicPlaylistID: String,
        scope: PlaylistPlaybackScope = .active,
        items: [PlaylistItemRecord]? = nil
    ) -> PlaybackOrderState {
        _ = playbackModeVersion
        let scopedPlaylistID = scope.playbackOrderPlaylistID(for: musicPlaylistID)
        if let items {
            let scopedItems = items.filter { scope.includes($0) }
            return PlaybackOrderCoordinator.reconciledState(
                orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope),
                playerID: playerID,
                playlistID: scopedPlaylistID
            )
        }

        return PlaybackOrderStore.state(
            playerID: playerID,
            musicPlaylistID: scopedPlaylistID
        )
    }

    func startMonitoring(context: ModelContext) {
        guard monitorTask == nil else { return }
        disableMusicKitPlaybackModes()
        monitorIdleSince = nil
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refresh(context: context)
                if await self?.suspendMonitoringIfIdle() != false {
                    return
                }
            }
        }
    }

    /// Ticking while playback has been paused/stopped for a long time is
    /// pure waste — each tick runs SwiftData fetches on the main actor.
    /// Every play path calls startMonitoring, which resumes the loop.
    private func suspendMonitoringIfIdle() -> Bool {
        monitorIdleSince = PlaybackMonitorIdlePolicy.updatedIdleStart(
            current: monitorIdleSince,
            isPlaying: isPlaying,
            isDeliveryStalled: isDeliveryStalled,
            now: .now
        )
        guard PlaybackMonitorIdlePolicy.shouldSuspend(idleSince: monitorIdleSince, now: .now) else {
            return false
        }

        TrackMetadataDiagnostics.log("playback monitor suspended after idle timeout")
        monitorTask = nil
        monitorIdleSince = nil
        return true
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
        currentPlaylistScope = .active
        activeSession = nil
        activeQueueEntries = []
        activeQueueIndex = nil
        activePlaylistSnapshot = nil
        prefetchedArtworkTrackID = nil
        pendingQueueAdvanceLocalTrackID = nil
        pendingQueueAdvanceFromLocalTrackID = nil
        pendingQueueAdvanceStartedAt = nil
        lastLocalPlaybackStateFlushAt = nil
        lastLocalPlaybackStateIdentity = nil
        lastLoggedPlaybackRefreshSignature = nil
        didLogQueueEndWithoutRestart = false
        cachedSettings = nil
        knownMusicItemIDsCache = nil
        unresolvableMusicItemIDs.removeAll()
        monitorIdleSince = nil
        deliveryStallState = PlaybackDeliveryStallPolicy.State()
        deliveryRecoveryAttempts = 0
        isDeliveryStalled = false
        playbackIntended = false
        statusMessage = "Overplay data reset."
        hasRestoredLocalPlaybackState = false
        LocalPlaybackStateStore.clear(flushImmediately: true)
        PlaybackWaypointStore.clear(flushImmediately: true)
        PlaybackIdentityStore.clearAll(flushImmediately: true)
        NowPlayingMetadataService.update(track: nil, elapsed: 0, isPlaying: false)
    }

    func restoreLocalPlaybackDisplay(context: ModelContext) {
        guard currentTrack == nil else { return }
        guard let state = LocalPlaybackStateStore.load() else { return }

        do {
            guard let restored = try PlaybackRestorationService.displayRestoreState(from: state, in: context) else {
                return
            }

            currentPlaylistID = restored.musicPlaylistID
            currentPlaylistScope = .active
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

    func playPlaylist(
        _ playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        await startPlaylistPlayback(playlist, startingAt: nil, scope: scope, settings: settings, context: context)
    }

    func playPlaylist(
        _ playlist: PlaylistRecord,
        startingAt track: TrackRecord,
        scope: PlaylistPlaybackScope = .active,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        await startPlaylistPlayback(playlist, startingAt: track, scope: scope, settings: settings, context: context)
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    private func startPlaylistPlayback(
        _ playlist: PlaylistRecord,
        startingAt trackRecord: TrackRecord?,
        scope: PlaylistPlaybackScope,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        do {
            let startingTrackID = trackRecord?.id.uuidString
            let queueEntries = try PlaybackQueueOrchestrator.orderedCachedQueueEntries(
                for: playlist.musicPlaylistID,
                playerID: playerID,
                startingTrackID: startingTrackID,
                scope: scope,
                in: context
            )
            guard !queueEntries.isEmpty else {
                statusMessage = "No locally cached \(scope.title.lowercased()) tracks for \(playlist.name)."
                return
            }
            if let startingTrackID,
               !queueEntries.contains(where: { $0.localTrackID == startingTrackID }) {
                statusMessage = "That track is not in the \(scope.title.lowercased()) playlist."
                return
            }

            try await startPlayback(
                queueEntries: queueEntries,
                playlistID: playlist.musicPlaylistID,
                scope: scope,
                startingAt: startingTrackID,
                outgoingSessionSettings: settings,
                context: context
            )
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
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
        scope: PlaylistPlaybackScope = .active,
        startingAt localTrackID: String?,
        outgoingSessionSettings: OverplaySettings? = nil,
        context: ModelContext
    ) async throws {
        guard !queueEntries.isEmpty else {
            statusMessage = "No playable tracks remain after local retirements."
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
        let materialization = materializeActiveQueue(entries: queueEntries, startingAt: localTrackID)
        player.queue = ApplicationMusicPlayer.Queue(
            materialization.queueEntries,
            startingAt: materialization.startingEntry
        )
        try await player.play()
        playbackIntended = true
        clearDeliveryFailure()
        currentPlaylistID = playlistID
        currentPlaylistScope = scope
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
                playbackIntended = false
            } else {
                try await player.play()
                playbackIntended = true
                clearDeliveryFailure()
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
            playbackIntended = true
            clearDeliveryFailure()
            startMonitoring(context: context)
            await refresh(context: context)
        } catch {
            statusMessage = musicPlaybackFailureMessage(for: error)
        }
    }

    func pause() {
        player.pause()
        playbackIntended = false
        elapsedSeconds = player.playbackTime
        isPlaying = false
        if let musicItemID = currentTrack?.id {
            persistLocalPlaybackState(musicItemID: musicItemID, forceFlush: true)
        }
        updateMusicKitNowPlayingTrack()
        NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: false)
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        // The monitor keeps polling while skipToNextEntry is in flight; the
        // transition flag stops a concurrent refresh from moving the queue
        // index or session out from under this method.
        isPerformingTransition = true
        defer { isPerformingTransition = false }

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
            let preTransitionIndex = activeQueueIndex
            try await player.skipToNextEntry()
            updateMusicKitNowPlayingTrack()
            activeQueueIndex = PlaybackQueueCoordinator.reconciledTransitionIndex(
                playerReportedEntryID: player.queue.currentEntry?.id,
                activeQueueEntries: activeQueueEntries,
                preTransitionIndex: preTransitionIndex,
                offset: 1
            )
            updateDisplayedTrackFromActiveQueue(
                context: context,
                transitionedFromLocalTrackID: skippedLocalTrackID
            )
            isPerformingTransition = false
            await refresh(context: context)
        } catch {
            isPerformingTransition = false
            guard PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
                activeQueueIndex: activeQueueIndex,
                activeQueueCount: activeQueueEntries.count,
                hasCurrentEntry: player.queue.currentEntry != nil
            ) else {
                // Mid-queue with a live entry, the skip can only have failed
                // because the player couldn't deliver the next track — don't
                // even attempt the queue-end restart while delivery is down.
                reportDeliveryFailure(message: musicPlaybackFailureMessage(for: error))
                return
            }
            if let skippedTrackID,
               await handleQueueEnded(
                   lastMusicItemID: skippedTrackID,
                   lastLocalTrackID: skippedLocalTrackID,
                   context: context
               ) {
                return
            }
            if !isDeliveryStalled {
                statusMessage = error.localizedDescription
            }
        }
    }

    func previous(context: ModelContext) async {
        isPerformingTransition = true
        defer { isPerformingTransition = false }

        markActiveSessionEvaluatedWithoutSkip()
        let outgoingLocalTrackID = currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID

        do {
            let preTransitionIndex = activeQueueIndex
            try await player.skipToPreviousEntry()
            updateMusicKitNowPlayingTrack()
            activeQueueIndex = PlaybackQueueCoordinator.reconciledTransitionIndex(
                playerReportedEntryID: player.queue.currentEntry?.id,
                activeQueueEntries: activeQueueEntries,
                preTransitionIndex: preTransitionIndex,
                offset: -1
            )
            updateDisplayedTrackFromActiveQueue(
                context: context,
                transitionedFromLocalTrackID: outgoingLocalTrackID
            )
            isPerformingTransition = false
            await refresh(context: context)
        } catch {
            isPerformingTransition = false
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
            let scopedItems = inputs.items.filter { currentPlaylistScope.includes($0) }
            let currentLocalTrackID = currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID
                ?? currentTrack.flatMap { localTrackID(matching: $0.id, context: context) }
            let orderedTrackIDs = PlaybackOrderCoordinator.reshuffle(
                playerID: playerID,
                playlistID: currentPlaylistScope.playbackOrderPlaylistID(for: currentPlaylistID),
                orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: currentPlaylistScope),
                avoiding: currentLocalTrackID
            )
            let queueEntries = PlaybackQueueOrchestrator.cachedQueueEntries(
                orderedTrackIDs: orderedTrackIDs,
                itemsByTrackID: scopedItems.firstValueDictionary(keyedBy: \.trackID),
                tracksByID: inputs.tracksByID
            )
            disableMusicKitPlaybackModes()
            playbackModeVersion += 1
            try await startPlayback(
                queueEntries: queueEntries,
                playlistID: currentPlaylistID,
                scope: currentPlaylistScope,
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
                scope: currentPlaylistScope,
                retainedTrackID: currentLocalTrackID,
                in: context
            )
            guard !queueEntries.isEmpty else { return }
            let startingLocalTrackID = currentLocalTrackID
                ?? currentMusicItemID.flatMap { localTrackID(matching: $0, context: context) }

            disableMusicKitPlaybackModes()
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
            try TrackActionService.keepCurrentTrack(
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
            try await promoteTrack(target.item, playlist: target.playlist, context: context)
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
            try TrackActionService.protectTrack(
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
            try TrackActionService.setProtected(
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
            try TrackActionService.resetSkipCount(
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
        try TrackActionService.restoreTrack(item, playlist: playlist, in: context)
        if let playlist {
            movePlaylistItemToBottom(item, playlist: playlist, scope: .active, context: context)
        }
        refreshCurrentPlaybackMetadata(context: context)
        rebuildActivePlaylistSnapshot(context: context)
    }

    @discardableResult
    func promoteTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        context: ModelContext
    ) async throws -> PlaylistItemRecord {
        let promotedItem = try await PlaylistMutationService().promote(item: item, in: context)
        if item.evictedAt != nil {
            movePlaylistItemToBottom(item, playlist: playlist, scope: .retired, context: context)
        }
        refreshCurrentPlaybackMetadata(context: context)
        rebuildActivePlaylistSnapshot(context: context)
        return promotedItem
    }

    func retireTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        context: ModelContext
    ) throws {
        try TrackActionService.evictTrack(item, playlist: playlist, message: message, in: context)
        movePlaylistItemToBottom(item, playlist: playlist, scope: .retired, context: context)
        refreshCurrentPlaybackMetadata(context: context)
        rebuildActivePlaylistSnapshot(context: context)
    }

    @discardableResult
    func restoreCurrent(context: ModelContext) -> Bool {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a retired track to restore."
            return false
        }

        do {
            try TrackActionService.restoreTrack(target.item, playlist: target.playlist, in: context)
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        movePlaylistItemToBottom(target.item, playlist: target.playlist, scope: .active, context: context)
        currentPlaylistItem = target.item
        syncPlaybackMetadata(for: target.musicItemID, trustedPlaylistItem: target.item, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        statusMessage = "Restored \(currentTrack?.title ?? "track")."
        return true
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
        guard let target = currentPlaybackTarget(context: context) else {
            statusMessage = "Choose a linked playlist track to retire."
            return
        }

        do {
            try retireTrack(
                target.item,
                playlist: target.playlist,
                message: "Retired manually",
                context: context
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

    private func movePlaylistItemToBottom(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope,
        context: ModelContext
    ) {
        do {
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            PlaybackOrderCoordinator.moveTrackIDToBottom(
                item.trackID.uuidString,
                playerID: playerID,
                playlistID: playlist.musicPlaylistID,
                items: items,
                targetScope: scope
            )
            playbackModeVersion += 1
        } catch {
            statusMessage = "Updated \(item.trackID.uuidString), but refreshing playlist order failed: \(error.localizedDescription)"
        }
    }

    private func refresh(context: ModelContext) async {
        // A user transition is mid-flight: reconciling identity now would
        // race the pending skip. Track time and play state only.
        if isPerformingTransition {
            elapsedSeconds = player.playbackTime
            isPlaying = player.state.playbackStatus == .playing
            NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
            return
        }

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

        await trackDeliveryHealth(
            status: player.state.playbackStatus,
            hasCurrentEntry: player.queue.currentEntry != nil,
            playbackTime: currentPlaybackTime
        )

        // Queue end never surfaces as a nil resolved identity, because
        // identity resolution falls back to the cached active queue entry
        // and session. Detect it from the player state directly, and only
        // restart when the outgoing session was observed near its end so an
        // external stop mid-track cannot trigger a surprise restart.
        let queueDidEnd = PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: player.queue.currentEntry != nil,
            playbackStatus: player.state.playbackStatus,
            hasActiveQueue: !activeQueueEntries.isEmpty,
            isRestartingQueue: isRestartingQueue
        )
        if queueDidEnd {
            let queueEndLocalTrackID = oldLocalTrackID
                ?? oldCurrentItemLocalTrackID
                ?? oldActiveQueueLocalTrackID
            if let oldTrackID, PlaybackQueueEndPolicy.shouldRestartAfterQueueEnd(session: activeSession) {
                TrackMetadataDiagnostics.log(
                    "queue ended naturally status=\(player.state.playbackStatus) lastTrackID=\(oldTrackID) lastLocalTrackID=\(queueEndLocalTrackID ?? "nil")"
                )
                didLogQueueEndWithoutRestart = false
                if let settings = monitoredSettings(context: context) {
                    await evaluateActiveSession(
                        settings: settings,
                        context: context,
                        naturalCompletion: true,
                        elapsedSeconds: activeSession?.lastObservedPlaybackTime,
                        durationSeconds: activeSession?.durationSeconds,
                        fallbackLocalTrackID: queueEndLocalTrackID
                    )
                }

                if await handleQueueEnded(
                    lastMusicItemID: oldTrackID,
                    lastLocalTrackID: queueEndLocalTrackID,
                    context: context
                ) {
                    return
                }
            } else {
                // The player abandoned the queue mid-track and the
                // anti-surprise-restart guard declined to restart. If
                // Overplay believed it was playing, this is a delivery
                // failure the user deserves to hear about — but it is
                // indistinguishable from an external stop, so never
                // auto-resume from here.
                if !didLogQueueEndWithoutRestart, playbackIntended {
                    reportDeliveryFailure(message: Self.playbackStoppedMessage)
                }
                logQueueEndWithoutRestartIfNeeded()
            }
        } else {
            didLogQueueEndWithoutRestart = false
        }

        let didChangeTrack = playbackIdentityDidChange(
            oldTrackID: oldTrackID,
            oldLocalTrackID: oldLocalTrackID,
            newTrackID: newTrackID,
            newLocalTrackID: newLocalTrackID,
            context: context
        )

        if didChangeTrack, let settings = monitoredSettings(context: context) {
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
            currentPlaylistScope = .active
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
        newLocalTrackID: String?,
        context: ModelContext
    ) -> Bool {
        let didChange = PlaybackIdentityFallbackPolicy.identityDidChange(
            oldMusicItemID: oldTrackID,
            oldLocalTrackID: oldLocalTrackID,
            newMusicItemID: newTrackID,
            newLocalTrackID: newLocalTrackID,
            currentTrackKnownMusicItemIDs: self.currentTrackKnownMusicItemIDs(context: context)
        )

        if !didChange,
           let oldTrackID,
           let newTrackID,
           oldTrackID != newTrackID,
           let currentPlaylistID,
           let localTrackID = oldLocalTrackID
               ?? currentPlaylistItem?.trackID.uuidString
               ?? activeQueueCurrentLocalTrackID {
            // Remember the other-domain ID so future scoped lookups resolve
            // it directly instead of re-deriving the correspondence.
            PlaybackIdentityStore.recordAlias(
                newTrackID,
                playerID: playerID,
                musicPlaylistID: currentPlaylistID,
                localTrackID: localTrackID
            )
        }

        return didChange
    }

    private func currentTrackKnownMusicItemIDs(context: ModelContext) -> Set<String> {
        let localTrackID = currentPlaylistItem?.trackID
            ?? (activeSession?.localTrackID).flatMap(UUID.init(uuidString:))
            ?? activeQueueCurrentLocalTrackID.flatMap(UUID.init(uuidString:))
        guard let localTrackID else { return [] }
        return knownMusicItemIDs(forLocalTrackID: localTrackID, context: context)
    }

    private func knownMusicItemIDs(forLocalTrackID localTrackID: UUID, context: ModelContext) -> Set<String> {
        if let knownMusicItemIDsCache, knownMusicItemIDsCache.localTrackID == localTrackID {
            return knownMusicItemIDsCache.ids
        }

        // A missing record is not cached: sync or an identity merge may
        // create it, and bumpPlaybackItemMetadataVersion (called on every
        // metadata change) invalidates positive entries.
        guard let record = try? TrackRecordRepository.track(id: localTrackID, in: context) else {
            return []
        }

        let ids = Set(PlaybackQueueBuilder.musicItemIDs(for: record))
        knownMusicItemIDsCache = (localTrackID, ids)
        return ids
    }

    private func monitoredSettings(context: ModelContext) -> OverplaySettings? {
        if let cachedSettings, !cachedSettings.isDeleted {
            return cachedSettings
        }

        cachedSettings = try? SettingsRepository.settings(in: context)
        return cachedSettings
    }

    private func session(_ session: TrackPlaySession, matches identity: CurrentPlaybackIdentity) -> Bool {
        if let sessionLocalTrackID = session.localTrackID,
           let identityLocalTrackID = identity.localTrackID {
            return sessionLocalTrackID == identityLocalTrackID
        }

        return session.trackID == identity.musicItemID
    }

    private func evaluatePlaythroughIfNeeded(context: ModelContext) {
        guard let settings = monitoredSettings(context: context) else { return }
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
                "Retired locally. Remote deletes only apply to the One True Playlist."
            } else {
                "Retired locally. \(playlist.name) is incoming only, so Apple Music was not changed."
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
            statusMessage = "Retired locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
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
        if outcome.evictedDuringEvaluation,
           let item = outcome.item,
           let playlist = outcome.playlist {
            movePlaylistItemToBottom(item, playlist: playlist, scope: .retired, context: context)
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
        // A miss ends in PlaybackQueueCoordinator's full TrackRecord scan.
        // When an unresolvable track is playing, the 1 Hz refresh would
        // repeat that scan every tick — remember the miss until the next
        // metadata change (sync, merge, or track transition) could heal it.
        guard !unresolvableMusicItemIDs.contains(musicItemID) else { return nil }

        if let resolved = resolveLocalTrackID(matching: musicItemID, playlistID: playlistID, context: context) {
            return resolved
        }

        unresolvableMusicItemIDs.insert(musicItemID)
        return nil
    }

    private func resolveLocalTrackID(
        matching musicItemID: String,
        playlistID: String?,
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
           knownMusicItemIDs(forLocalTrackID: trackID, context: context).contains(musicItemID) {
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
                       activeQueueMusicItemID: activeQueueCurrentEntry.queuedMusicItemID
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

        if let activeQueueCurrentEntry {
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

        guard let activeQueueCurrentEntry,
              activeQueueCurrentEntry.localTrackID == pendingQueueAdvanceLocalTrackID else {
            clearPendingQueueAdvance()
            return nil
        }

        let confirmedLocalTrackID: String? = {
            guard let queueEntry = player.queue.currentEntry else { return nil }
            if let realizedEntry = activeQueueEntries.first(where: { $0.queueEntryID == queueEntry.id }) {
                return realizedEntry.localTrackID
            }
            if let queueReportedTrackID = queueEntry.item?.id.rawValue {
                return localTrackID(matching: queueReportedTrackID, context: context)
            }
            return nil
        }()

        switch PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: pendingQueueAdvanceLocalTrackID,
            fromLocalTrackID: pendingQueueAdvanceFromLocalTrackID,
            confirmedLocalTrackID: confirmedLocalTrackID,
            startedAt: pendingQueueAdvanceStartedAt
        ) {
        case .arrived, .diverged, .expired:
            clearPendingQueueAdvance()
            return nil
        case .propagating, .pinned:
            return CurrentPlaybackIdentity(
                musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
                localTrackID: activeQueueCurrentEntry.localTrackID,
                playlistItemID: activeQueueCurrentEntry.playlistItemID,
                isQueueCorrelated: true,
                source: "pendingQueueAdvance"
            )
        }
    }

    private func clearPendingQueueAdvanceIfNeeded(matchedLocalTrackID: String) {
        guard pendingQueueAdvanceLocalTrackID == matchedLocalTrackID else { return }
        clearPendingQueueAdvance()
    }

    private func clearPendingQueueAdvance() {
        pendingQueueAdvanceLocalTrackID = nil
        pendingQueueAdvanceFromLocalTrackID = nil
        pendingQueueAdvanceStartedAt = nil
    }

    private func logQueueEndWithoutRestartIfNeeded() {
        guard !didLogQueueEndWithoutRestart else { return }
        didLogQueueEndWithoutRestart = true
        let sessionDescription = activeSession.map {
            "\($0.trackID)@\(String(format: "%.1f", $0.lastObservedPlaybackTime))/\($0.durationSeconds.map { String(format: "%.1f", $0) } ?? "nil")"
        } ?? "nil"
        TrackMetadataDiagnostics.log(
            "queue ended without restart status=\(player.state.playbackStatus) session=\(sessionDescription)"
        )
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
        knownMusicItemIDsCache = nil
        unresolvableMusicItemIDs.removeAll()
        playbackItemMetadataVersion += 1
    }

    private func updateDisplayedTrackFromActiveQueue(
        context: ModelContext,
        transitionedFromLocalTrackID: String? = nil
    ) {
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
        pendingQueueAdvanceFromLocalTrackID = transitionedFromLocalTrackID
        pendingQueueAdvanceStartedAt = .now
        bumpPlaybackItemMetadataVersion()
        updateActivePlaylistSnapshotCurrentRow()
        NowPlayingMetadataService.update(track: nowPlayingDisplayTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
        persistLocalPlaybackState(
            musicItemID: activeQueueCurrentEntry.queuedMusicItemID,
            localTrackID: activeQueueCurrentEntry.localTrackID
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
            let reshuffled = try PlaybackQueueOrchestrator.previewedReshuffledQueue(
                playlistID: currentPlaylistID,
                playerID: playerID,
                scope: currentPlaylistScope,
                avoiding: lastLocalTrackID ?? localTrackID(
                    matching: lastMusicItemID,
                    playlistID: currentPlaylistID,
                    context: context
                ),
                in: context
            )
            guard !reshuffled.entries.isEmpty else { return false }

            disableMusicKitPlaybackModes()
            let startingLocalTrackID = reshuffled.entries.first?.localTrackID
            let materialization = PlaybackQueueMaterializer.materialize(
                reshuffled.entries,
                startingAt: startingLocalTrackID
            )
            player.queue = ApplicationMusicPlayer.Queue(
                materialization.queueEntries,
                startingAt: materialization.startingEntry
            )
            do {
                try await player.play()
            } catch {
                // The player refused the new queue (offline, Music app dead).
                // Nothing has been persisted or adopted yet: put the player
                // queue back where the user was so a later manual play
                // resumes there instead of at a random reshuffled track.
                restorePlayerQueueAfterFailedRestart(
                    resumeLocalTrackID: activeQueueCurrentLocalTrackID ?? lastLocalTrackID,
                    context: context
                )
                reportDeliveryFailure(message: musicPlaybackFailureMessage(for: error))
                return false
            }

            // Play is confirmed: only now adopt the new queue and persist
            // the reshuffled order.
            updateActiveQueue(realizedEntries: materialization.realizedEntries, startingAt: startingLocalTrackID)
            PlaybackQueueOrchestrator.persistReshuffledOrder(
                reshuffled.orderedTrackIDs,
                playlistID: currentPlaylistID,
                playerID: playerID,
                scope: currentPlaylistScope
            )
            playbackModeVersion += 1
            playbackIntended = true
            await refresh(context: context)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// A restart replaced the live player queue before `play()` failed. The
    /// stored order was deliberately not overwritten, so rebuild the queue
    /// from it, positioned at the track the user was on, and re-correlate
    /// the active queue with the restored player entries.
    private func restorePlayerQueueAfterFailedRestart(resumeLocalTrackID: String?, context: ModelContext) {
        guard let currentPlaylistID else { return }
        guard let entries = try? PlaybackQueueOrchestrator.orderedCachedQueueEntries(
            for: currentPlaylistID,
            playerID: playerID,
            startingTrackID: resumeLocalTrackID,
            scope: currentPlaylistScope,
            in: context
        ), !entries.isEmpty else { return }

        let materialization = materializeActiveQueue(entries: entries, startingAt: resumeLocalTrackID)
        player.queue = ApplicationMusicPlayer.Queue(
            materialization.queueEntries,
            startingAt: materialization.startingEntry
        )
    }

    private func trackDeliveryHealth(
        status: MusicPlayer.PlaybackStatus,
        hasCurrentEntry: Bool,
        playbackTime: Double
    ) async {
        guard currentPlaylistID != nil, !activeQueueEntries.isEmpty else {
            deliveryStallState = PlaybackDeliveryStallPolicy.State()
            return
        }

        deliveryStallState = PlaybackDeliveryStallPolicy.assess(
            deliveryStallState,
            tick: PlaybackDeliveryStallPolicy.Tick(
                playbackStatus: status,
                hasCurrentEntry: hasCurrentEntry,
                playbackTime: playbackTime
            )
        )

        if deliveryStallState.isProgressing {
            clearDeliveryFailure()
            return
        }

        guard deliveryStallState.isStalled else { return }

        if !isDeliveryStalled {
            reportDeliveryFailure(message: Self.deliveryStallMessage)
            TrackMetadataDiagnostics.log(
                "playback delivery stalled status=\(status) time=\(String(format: "%.1f", playbackTime)) interrupted=\(deliveryStallState.interruptedTicks) frozen=\(deliveryStallState.frozenTicks)"
            )
        }

        await attemptDeliveryRecoveryIfNeeded()
    }

    private func attemptDeliveryRecoveryIfNeeded() async {
        guard !isAttemptingDeliveryRecovery,
              PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
                  state: deliveryStallState,
                  playbackIntended: playbackIntended,
                  isNetworkReachable: isNetworkReachable(),
                  attemptsMade: deliveryRecoveryAttempts
              ) else {
            return
        }

        isAttemptingDeliveryRecovery = true
        defer { isAttemptingDeliveryRecovery = false }
        deliveryRecoveryAttempts += 1
        let attempt = deliveryRecoveryAttempts
        do {
            try await player.prepareToPlay()
            try await player.play()
            // The next progressing tick confirms recovery and clears the
            // surfaced failure; reset the detector so its stale counters
            // don't immediately re-trip it.
            deliveryStallState = PlaybackDeliveryStallPolicy.State()
            TrackMetadataDiagnostics.log("playback delivery recovery attempt \(attempt) resumed playback")
        } catch {
            TrackMetadataDiagnostics.log(
                "playback delivery recovery attempt \(attempt) failed: \(error.localizedDescription)"
            )
        }
    }

    private func reportDeliveryFailure(message: String) {
        isDeliveryStalled = true
        statusMessage = message
    }

    private func clearDeliveryFailure() {
        deliveryRecoveryAttempts = 0
        guard isDeliveryStalled else { return }
        isDeliveryStalled = false
        if statusMessage == Self.deliveryStallMessage || statusMessage == Self.playbackStoppedMessage {
            statusMessage = nil
        }
    }

    /// A trusted point-in-time observation of the out-of-process player for
    /// suspended-playback reconciliation. Reads live player state rather
    /// than the cached display, which may be stale during a background wake.
    func capturePlaybackObservation(context: ModelContext) -> PlaybackReconciliationPolicy.Observation? {
        guard let queueEntry = player.queue.currentEntry else { return nil }
        guard let playlistID = currentPlaylistID ?? LocalPlaybackStateStore.load()?.playlistID else {
            return nil
        }

        var localTrackID = activeQueueEntries.first(where: { $0.queueEntryID == queueEntry.id })?.localTrackID
        if localTrackID == nil, let musicItemID = queueEntry.item?.id.rawValue {
            localTrackID = self.localTrackID(matching: musicItemID, playlistID: playlistID, context: context)
        }
        guard let localTrackID else { return nil }

        let duration = durationSeconds
            ?? currentTrack?.durationSeconds
            ?? UUID(uuidString: localTrackID)
                .flatMap { try? TrackRecordRepository.track(id: $0, in: context) }?
                .durationSeconds

        return PlaybackReconciliationPolicy.Observation(
            playlistID: playlistID,
            localTrackID: localTrackID,
            positionSeconds: player.playbackTime,
            durationSeconds: duration,
            observedAt: .now
        )
    }

    /// Suspended-playback reconciliation counted the currently playing
    /// track; mark the live session evaluated so the monitor cannot count
    /// the same play again.
    func markActiveSessionPlaythroughCounted(localTrackID: String) {
        guard var session = activeSession, !session.hasEvaluated else { return }
        let sessionLocalTrackID = session.localTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID
        guard sessionLocalTrackID == localTrackID else { return }
        session.hasEvaluated = true
        activeSession = session
    }

    /// True when the live session for this track has already been counted,
    /// so reconciliation must not count the same play again.
    func activeSessionHasEvaluated(localTrackID: String) -> Bool {
        guard let session = activeSession, session.hasEvaluated else { return false }
        let sessionLocalTrackID = session.localTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeQueueCurrentLocalTrackID
        return sessionLocalTrackID == localTrackID
    }

    /// Reconciles the stored local order with current playlist membership.
    /// Called on membership-changing events (sync completion, link changes,
    /// manual add, promotion) — not from the playback tick, which only needs
    /// to track the current entry. Duplicate cleanup happens in the track
    /// identity merge pass at startup and after sync, not here.
    func reconcileStoredOrder(for playlist: PlaylistRecord, context: ModelContext) {
        // Membership changed (sync, link change, manual add): previously
        // unresolvable music item IDs may now have records.
        unresolvableMusicItemIDs.removeAll()
        let currentLocalTrackID = currentPlaylistID == playlist.musicPlaylistID && currentPlaylistScope == .active
            ? currentPlaylistItem?.trackID.uuidString
            : nil
        do {
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let activeItems = items.filter { PlaylistPlaybackScope.active.includes($0) }
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: activeItems)
            let previousState = PlaybackOrderStore.state(
                playerID: playerID,
                musicPlaylistID: PlaylistPlaybackScope.active.playbackOrderPlaylistID(for: playlist.musicPlaylistID)
            )
            let playableOrder = PlaybackOrderEngine.normalOrder(for: orderTracks, includeUnplayableTrackID: currentLocalTrackID)
            let reconciledOrder: [String]
            if currentPlaylistID == playlist.musicPlaylistID,
               currentPlaylistScope == .active,
               !previousState.orderedTrackIDs.isEmpty {
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
                if currentPlaylistID == playlist.musicPlaylistID,
                   currentPlaylistScope == .active,
                   !appendedIDs.isEmpty {
                    Task { @MainActor [weak self] in
                        await self?.appendLiveQueueEntries(
                            localTrackIDs: appendedIDs,
                            playlistID: playlist.musicPlaylistID,
                            context: context
                        )
                    }
                }
                if currentPlaylistID == playlist.musicPlaylistID {
                    rebuildActivePlaylistSnapshot(context: context)
                }
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
                    musicPlaylistID: currentPlaylistScope.playbackOrderPlaylistID(for: currentPlaylistID)
                ),
                playbackScope: currentPlaylistScope,
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
