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

    private struct OutgoingPlaybackTransition {
        var entryID: String?
        var musicItemID: String?
        var localTrackID: String?
        var elapsedSeconds: Double
        var durationSeconds: Double?
        var wasPlaying: Bool
    }

    private enum PlayerTransitionResult {
        case confirmed(entryID: String)
        case diverged(entryID: String)
        case failed(any Error)
        case timedOut
        case rejected
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
    /// True while streaming delivery is failing (a frozen mid-track stream
    /// or a restart the player refused). Cleared by witnessed playback
    /// progress, an active system interruption, or a successful user-initiated
    /// play. CarPlay watches this to surface an alert — statusMessage renders
    /// only in the iPhone/iPad Now Playing views.
    private(set) var isDeliveryStalled = false
    private(set) var isPlaybackTransitionInFlight = false
    /// Whether the shared player is holding a queue entry.
    ///
    /// Mirrored into observable state deliberately: `MusicPlayer.Queue` is
    /// not observable, and the entry-level correlation below is
    /// `@ObservationIgnored`, so without this a SwiftUI control or a
    /// remote-command sync could not see track navigation become available.
    private(set) var hasLivePlayerEntry = false
    private(set) var playbackItemMetadataVersion = 0
    private(set) var playbackModeVersion = 0

    @ObservationIgnored private let player: any PlaybackPlayer
    @ObservationIgnored private let transitionConfirmationPolicy: PlaybackTransitionConfirmationPolicy
    @ObservationIgnored private let sleepForTransitionConfirmation: @MainActor (Duration) async -> Void
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var warmUpTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: TrackPlaySession?
    @ObservationIgnored private var activePlaylistSnapshotNeedsRebuild = false
    @ObservationIgnored private var activeQueueEntries: [RealizedPlaybackQueueEntry] = []
    /// Where the current track sits in `activeQueueEntries`, which is
    /// Overplay's local order. A correlation cursor, not a play position: once
    /// MusicKit is shuffling, the order it plays in is its own and unknowable
    /// from here.
    @ObservationIgnored private var activeQueueIndex: Int?
    @ObservationIgnored private var hasRestoredLocalPlaybackState = false
    @ObservationIgnored private var prefetchedArtworkTrackID: String?
    /// The player entry `musicKitNowPlayingTrack` describes. Without it, an
    /// entry change the player has not hydrated yet is indistinguishable
    /// from the same entry momentarily losing its item.
    @ObservationIgnored private var musicKitNowPlayingEntryID: String?
    /// Live player-queue entries that had an item and still matched no row
    /// of the current playlist. Rebuilding reads the whole playlist, and the
    /// 1 Hz tick would otherwise retry a queue holding foreign entries every
    /// second. Cleared by any metadata change, which is what could heal the
    /// membership.
    @ObservationIgnored private var unmappableLiveEntryIDs: Set<String> = []
    @ObservationIgnored private var isPerformingTransition = false
    @ObservationIgnored private var lastLocalPlaybackStateFlushAt: Date?
    @ObservationIgnored private var lastLocalPlaybackStateIdentity: LocalPlaybackStateIdentity?
    @ObservationIgnored private var lastLoggedPlaybackRefreshSignature: String?
    @ObservationIgnored private var didLogQueueEndWithoutRestart = false
    /// True once a queue end has been handled, so the state — which stays true
    /// every tick until something changes it — cannot be handled again.
    @ObservationIgnored private var didHandleQueueEnd = false
    /// The modes as last seen. `MusicPlayer.State` is not observable, so the
    /// only way another surface's change reaches Overplay is by comparing.
    @ObservationIgnored private var lastObservedShuffleMode: MusicPlayer.ShuffleMode?
    @ObservationIgnored private var lastObservedRepeatMode: MusicPlayer.RepeatMode?
    /// Raw optionals are tracked separately because MusicKit can report nil.
    /// Treating nil as off is existing playback behavior, but diagnostics must
    /// preserve the distinction while investigating transient mode changes.
    @ObservationIgnored private var lastReportedShuffleMode: MusicPlayer.ShuffleMode?
    @ObservationIgnored private var lastReportedRepeatMode: MusicPlayer.RepeatMode?
    @ObservationIgnored private var hasObservedPlaybackModes = false
    /// Entries the player accepted from an append but has not reported an item
    /// ID for yet. Correlation is retried until it succeeds, because reaching
    /// an uncorrelated entry reads as divergence and tears playback down.
    @ObservationIgnored private var appendedUncorrelatedEntries: [PendingQueueCorrelation] = []
    /// Local IDs scheduled by reconciliation but not yet represented in the
    /// player or pending-correlation arrays. Prevents two near-simultaneous
    /// sync completions from enqueueing the same top-up twice.
    @ObservationIgnored private var reconciliationPendingAppendTrackIDs = Set<String>()
    /// Bumped whenever the live queue correlation is replaced or discarded.
    /// An append that returns against an older generation must not register
    /// entries from the queue it started against.
    @ObservationIgnored private var appendCorrelationGeneration = 0
    @ObservationIgnored private var deliveryStallState = PlaybackDeliveryStallPolicy.State()
    @ObservationIgnored private var deliveryInterruptionGeneration = 0
    @ObservationIgnored private var unresolvedEntryState = PlaybackUnresolvedEntryPolicy.State()
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

    init(
        playerID: String = "main",
        player: any PlaybackPlayer = ApplicationMusicPlaybackPlayer(),
        transitionConfirmationPolicy: PlaybackTransitionConfirmationPolicy = .standard,
        sleepForTransitionConfirmation: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.playerID = playerID
        self.player = player
        self.transitionConfirmationPolicy = transitionConfirmationPolicy
        self.sleepForTransitionConfirmation = sleepForTransitionConfirmation
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

    /// Publishes system Now Playing metadata for the current display track.
    ///
    /// `ownsPlayback` is read from the shared player rather than from cached
    /// state: Overplay may hold a restored display track (at launch, or after
    /// the monitor suspended) while the shared player holds nothing, and in
    /// that case it must not claim the system Now Playing session from
    /// whatever really is playing.
    private func publishNowPlayingMetadata(isPlaying: Bool) {
        NowPlayingMetadataService.update(
            track: nowPlayingDisplayTrack,
            elapsed: elapsedSeconds,
            isPlaying: isPlaying,
            ownsPlayback: player.currentEntry != nil
        )
    }

    var nowPlayingDisplayLocalTrackID: String? {
        guard currentPlaylistID != nil else { return nil }
        return activeQueueCurrentLocalTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeSession?.localTrackID
    }

    var canControlPlayback: Bool {
        currentPlaylistID != nil && currentTrack != nil && activeQueueIndex != nil
    }

    /// Whether track navigation and mode changes can be handed to the player.
    ///
    /// Deliberately not gated on queue correlation. The player skips inside,
    /// shuffles and repeats the queue it is holding; which entry Overplay
    /// believes is current is its own bookkeeping. Gating on that left Next,
    /// Previous, shuffle and repeat inert — on the iPhone controls and on
    /// every system surface at once — while a queue was playing perfectly
    /// well.
    var canSkipTracks: Bool {
        hasLivePlayerEntry
    }

    var remoteCommandAvailability: PlaybackRemoteCommandAvailability {
        PlaybackRemoteCommandAvailability.make(
            canSkipTracks: canSkipTracks,
            hasRestorablePlayback: currentPlaylistID != nil && currentTrack != nil,
            isPlaying: isPlaying,
            isTransitionInFlight: isPlaybackTransitionInFlight,
            isDeliveryStalled: isDeliveryStalled
        )
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
        return player.shuffleMode != .off
    }

    var repeatMode: MusicPlayer.RepeatMode {
        _ = playbackModeVersion
        return player.repeatMode
    }

    var repeatAllEnabled: Bool {
        _ = playbackModeVersion
        return player.repeatMode == .all
    }

    var playbackModeDiagnosticDescription: String {
        "rawShuffle=\(Self.modeDescription(player.reportedShuffleMode)) "
            + "effectiveShuffle=\(player.shuffleMode) "
            + "rawRepeat=\(Self.modeDescription(player.reportedRepeatMode)) "
            + "effectiveRepeat=\(player.repeatMode)"
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

    /// Read-only counterpart of `playbackOrderState(for:scope:items:)` for
    /// presentation code — never persists the reconciled order, so it is
    /// safe to call while building view state.
    func previewedPlaybackOrderState(
        for musicPlaylistID: String,
        scope: PlaylistPlaybackScope = .active,
        items: [PlaylistItemRecord]
    ) -> PlaybackOrderState {
        _ = playbackModeVersion
        let scopedItems = items.filter { scope.includes($0) }
        return PlaybackOrderCoordinator.previewedReconciledState(
            orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope),
            playerID: playerID,
            playlistID: scope.playbackOrderPlaylistID(for: musicPlaylistID)
        )
    }

    func startMonitoring(context: ModelContext) {
        guard monitorTask == nil else { return }
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

    /// Reconciles one explicit player observation through the same path used
    /// by the active monitor. Background/system adapters and deterministic
    /// tests can use this without inventing a surface-specific state update.
    func reconcilePlayerState(context: ModelContext) async {
        await refresh(context: context)
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
        NowPlayingMetadataService.resetPublishedState()
        player.pause()
        currentTrack = nil
        musicKitNowPlayingTrack = nil
        musicKitNowPlayingEntryID = nil
        isMusicKitNowPlayingTrackPending = false
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        currentPlaylistID = nil
        currentPlaylistScope = .active
        activeSession = nil
        activeQueueEntries = []
        resetAppendedQueueCorrelations()
        activeQueueIndex = nil
        activePlaylistSnapshot = nil
        prefetchedArtworkTrackID = nil
        lastLocalPlaybackStateFlushAt = nil
        lastLocalPlaybackStateIdentity = nil
        lastLoggedPlaybackRefreshSignature = nil
        didLogQueueEndWithoutRestart = false
        cachedSettings = nil
        knownMusicItemIDsCache = nil
        unresolvableMusicItemIDs.removeAll()
        monitorIdleSince = nil
        deliveryStallState = PlaybackDeliveryStallPolicy.State()
        deliveryInterruptionGeneration = 0
        unresolvedEntryState = PlaybackUnresolvedEntryPolicy.State()
        deliveryRecoveryAttempts = 0
        isDeliveryStalled = false
        playbackIntended = false
        statusMessage = "Overplay data reset."
        hasRestoredLocalPlaybackState = false
        LocalPlaybackStateStore.clear(flushImmediately: true)
        PlaybackWaypointStore.clear(flushImmediately: true)
        PlaybackIdentityStore.clearAll(flushImmediately: true)
        NowPlayingMetadataService.update(track: nil, elapsed: 0, isPlaying: false, ownsPlayback: false)
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
            resetAppendedQueueCorrelations()
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

    /// True when `playlist` is the queue the player is actually playing, so a
    /// surface can jump inside that queue instead of rebuilding it.
    func currentQueueContains(playlist: PlaylistRecord, scope: PlaylistPlaybackScope) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID
            && currentPlaylistScope == scope
            && !activeQueueEntries.isEmpty
    }

    /// Skips to a track inside the live queue, preserving the order after it.
    /// Returns `false` when the track is not in the live queue, so the caller
    /// can fall back to building a fresh queue from that track.
    @discardableResult
    func playTrackInCurrentQueue(
        localTrackID: String,
        settings: OverplaySettings,
        context: ModelContext
    ) async -> Bool {
        // Reconcile first: an external queue replacement leaves
        // activeQueueEntries describing a queue the player no longer holds, and
        // skipping to an entry from it would fail as a stall instead of
        // letting the caller build a fresh queue.
        await refresh(context: context)
        guard let target = activeQueueEntries.first(where: { $0.localTrackID == localTrackID }) else {
            return false
        }

        let outgoing = captureOutgoingPlaybackTransition()
        guard outgoing.entryID != target.queueEntryID else {
            // Already the live entry: resume it rather than restart it.
            if !isPlaying {
                await play(context: context)
            }
            return true
        }

        let result = await performPlayerConfirmedTransition(
            outgoingEntryID: outgoing.entryID,
            expectedEntryIDs: [target.queueEntryID],
            command: {
                try await player.skipToEntry(withID: target.queueEntryID)
            },
            onObservedTransition: { _ in
                evaluateOutgoingTransition(
                    outgoing,
                    settings: settings,
                    naturalCompletion: false,
                    context: context
                )
            }
        )

        switch result {
        case .confirmed, .diverged:
            await refresh(context: context)
        case .failed(let error):
            await refresh(context: context)
            // The queue moved under us between reconciliation and the jump —
            // hand back to the caller rather than reporting a stall.
            guard (error as? PlaybackQueueEntryError) != .entryNotInQueue else {
                return false
            }
            reportDeliveryFailure(message: musicPlaybackFailureMessage(for: error))
        case .timedOut:
            await refresh(context: context)
            statusMessage = PlaybackTransitionError.confirmationTimedOut.localizedDescription
        case .rejected:
            break
        }
        return true
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

    /// The entries the player is holding right now, or nil when it holds
    /// none.
    ///
    /// Transition validation asks the player rather than Overplay's mapped
    /// queue. A re-materialized queue hydrates piecemeal, so the mapped
    /// queue can legitimately be a subset of it, and landing on an entry the
    /// player is demonstrably holding is not divergence — it is correlation
    /// that has not caught up yet.
    private var liveQueueEntryIDs: Set<String>? {
        let ids = Set(player.queueEntrySnapshots.map(\.id))
        return ids.isEmpty ? nil : ids
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
        resetAppendedQueueCorrelations()
        activeQueueEntries = state.entries
        activeQueueIndex = state.index
    }

    /// Invalidates append work associated with the previous live queue.
    private func resetAppendedQueueCorrelations() {
        appendedUncorrelatedEntries = []
        reconciliationPendingAppendTrackIDs = []
        appendCorrelationGeneration &+= 1
    }

    private func updateActiveQueueCurrentTrackID(_ localTrackID: String?) {
        activeQueueIndex = PlaybackQueueCoordinator.updatedActiveQueueIndex(
            localTrackID: localTrackID,
            activeQueueEntries: activeQueueEntries,
            currentIndex: activeQueueIndex
        )
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

    private func captureOutgoingPlaybackTransition() -> OutgoingPlaybackTransition {
        let currentEntry = player.currentEntry
        let realizedEntry = currentEntry.flatMap { currentEntry in
            activeQueueEntries.first { $0.queueEntryID == currentEntry.id }
        } ?? activeQueueCurrentEntry
        return OutgoingPlaybackTransition(
            entryID: currentEntry?.id ?? realizedEntry?.queueEntryID,
            musicItemID: currentEntry?.item?.id.rawValue
                ?? realizedEntry?.queuedMusicItemID
                ?? activeSession?.trackID
                ?? currentTrack?.id,
            localTrackID: realizedEntry?.localTrackID
                ?? activeSession?.localTrackID
                ?? currentPlaylistItem?.trackID.uuidString
                ?? activeQueueCurrentLocalTrackID,
            elapsedSeconds: activeSession?.lastObservedPlaybackTime ?? player.playbackTime,
            durationSeconds: activeSession?.durationSeconds ?? durationSeconds ?? currentTrack?.durationSeconds,
            wasPlaying: player.playbackStatus == .playing
        )
    }

    private func performPlayerConfirmedTransition(
        outgoingEntryID: String?,
        expectedEntryIDs: Set<String>? = nil,
        command: () async throws -> Void,
        onObservedTransition: (PlaybackTransitionConfirmation) async -> Void,
        onUnconfirmed: () async -> Void = {}
    ) async -> PlayerTransitionResult {
        guard !isPerformingTransition else {
            statusMessage = "Another playback transition is still being confirmed."
            return .rejected
        }

        isPerformingTransition = true
        isPlaybackTransitionInFlight = true
        defer {
            isPerformingTransition = false
            isPlaybackTransitionInFlight = false
        }

        do {
            try await command()
        } catch {
            await onUnconfirmed()
            return .failed(error)
        }

        let observationCount = max(transitionConfirmationPolicy.maximumObservationCount, 1)
        for observationIndex in 0..<observationCount {
            let resolution = transitionConfirmationPolicy.resolution(
                outgoingEntryID: outgoingEntryID,
                expectedEntryIDs: expectedEntryIDs,
                observedEntryID: player.currentEntry?.id
            )
            switch resolution {
            case .confirmed(let entryID):
                await onObservedTransition(resolution)
                return .confirmed(entryID: entryID)
            case .diverged(let entryID):
                await onObservedTransition(resolution)
                return .diverged(entryID: entryID)
            case .waiting:
                if observationIndex < observationCount - 1 {
                    await sleepForTransitionConfirmation(transitionConfirmationPolicy.observationInterval)
                }
            }
        }

        await onUnconfirmed()
        return .timedOut
    }

    private func evaluateOutgoingTransition(
        _ outgoing: OutgoingPlaybackTransition,
        settings: OverplaySettings,
        naturalCompletion: Bool,
        context: ModelContext
    ) {
        guard outgoing.musicItemID != nil || activeSession != nil else { return }
        evaluateActiveSession(
            settings: settings,
            context: context,
            naturalCompletion: naturalCompletion,
            elapsedSeconds: outgoing.elapsedSeconds,
            durationSeconds: outgoing.durationSeconds,
            fallbackLocalTrackID: outgoing.localTrackID
        )
    }

    private func shouldEvaluateOutgoingTransition(
        _ outgoing: OutgoingPlaybackTransition,
        targetPlaylistID: String,
        targetLocalTrackID: String?
    ) -> Bool {
        guard outgoing.musicItemID != nil || activeSession != nil else { return false }
        return currentPlaylistID != targetPlaylistID
            || targetLocalTrackID == nil
            || targetLocalTrackID != outgoing.localTrackID
    }

    /// Drops entry-level queue correlation while keeping Overplay's belief
    /// about what is playing, and keeping the durable restore state.
    ///
    /// Used when the player's current entry cannot be correlated but playback
    /// itself is fine. The full teardown below is for a confirmed diverged
    /// transition, where Overplay genuinely cannot say what is playing.
    private func clearQueueCorrelationPreservingPlayback() {
        activeQueueEntries = []
        activeQueueIndex = nil
        resetAppendedQueueCorrelations()
        activeSession = nil
        prefetchedArtworkTrackID = nil
        activePlaylistSnapshotNeedsRebuild = true
        bumpPlaybackItemMetadataVersion()
    }

    private func clearQueueCorrelationAfterDivergedTransition() {
        // The most consequential thing Overplay does to itself: this drops the
        // playlist, the rest of the queue and the durable restore point. From
        // a call log alone it is invisible, which made a device failure much
        // harder to read than it needed to be.
        //
        // Recorded only when there is something to drop. The predicate that
        // reaches here cannot be cleared by this function — it reads the array
        // this empties — so the 1 Hz tick calls it again every second, and an
        // unconditional record would fill the whole event buffer with no-ops
        // during exactly the failure it is meant to explain.
        if !activeQueueEntries.isEmpty || currentPlaylistID != nil {
            MusicKitActivityLog.shared.record(
                .queueCorrelationCleared,
                magnitude: Double(activeQueueEntries.count),
                detail: currentPlaylistID == nil ? "no current playlist" : "diverged transition"
            )
        }
        activeQueueEntries = []
        activeQueueIndex = nil
        resetAppendedQueueCorrelations()
        currentPlaylistID = nil
        currentPlaylistScope = .active
        currentPlaylistItem = nil
        currentTrack = nil
        musicKitNowPlayingTrack = nil
        musicKitNowPlayingEntryID = nil
        isMusicKitNowPlayingTrackPending = false
        durationSeconds = nil
        activeSession = nil
        activePlaylistSnapshot = nil
        activePlaylistSnapshotNeedsRebuild = false
        prefetchedArtworkTrackID = nil
        lastLocalPlaybackStateIdentity = nil
        LocalPlaybackStateStore.clear(flushImmediately: true)
        bumpPlaybackItemMetadataVersion()
    }

    private func startPlayback(
        queueEntries: [PlaybackQueueEntry],
        playlistID: String,
        scope: PlaylistPlaybackScope = .active,
        startingAt localTrackID: String?,
        confirmedPlaybackOrder: [String]? = nil,
        outgoingSessionSettings: OverplaySettings? = nil,
        context: ModelContext
    ) async throws {
        guard !queueEntries.isEmpty else {
            statusMessage = "No playable tracks remain after local retirements."
            return
        }

        await refresh(context: context)
        let outgoing = captureOutgoingPlaybackTransition()

        warmUpTask?.cancel()
        warmUpTask = nil

        // The whole order, in one hand-off. MusicKit owns shuffle and repeat
        // now, and it can only shuffle or loop what it actually holds.
        let materialization = PlaybackQueueMaterializer.materialize(queueEntries, startingAt: localTrackID)
        let expectedEntryIDs = Set(materialization.realizedEntries.map(\.queueEntryID))
        var didRecoverReissuedStart = false
        let result = await performPlayerConfirmedTransition(
            outgoingEntryID: outgoing.entryID,
            expectedEntryIDs: expectedEntryIDs,
            command: {
                        player.replaceQueue(with: materialization)
                try await player.play()
            },
            onObservedTransition: { confirmation in
                if let outgoingSessionSettings,
                   shouldEvaluateOutgoingTransition(
                       outgoing,
                       targetPlaylistID: playlistID,
                       targetLocalTrackID: localTrackID
                   ) {
                    evaluateOutgoingTransition(
                        outgoing,
                        settings: outgoingSessionSettings,
                        naturalCompletion: false,
                        context: context
                    )
                }

                switch confirmation {
                case .confirmed:
                    updateActiveQueue(realizedEntries: materialization.realizedEntries, startingAt: localTrackID)
                case .diverged:
                    // MusicKit can re-materialize a queue during the initial
                    // handoff, before Overplay has committed its playlist
                    // identity. Prove the live queue still belongs to the
                    // requested playlist and rebuild correlation just as we
                    // do for a later shuffle/repeat re-materialization.
                    currentPlaylistID = playlistID
                    currentPlaylistScope = scope
                    updateActiveQueue(realizedEntries: materialization.realizedEntries, startingAt: localTrackID)
                    recorrelateLiveQueueIfNeeded(currentEntry: player.currentEntry, context: context)
                    guard let currentEntry = player.currentEntry,
                          activeQueueEntries.contains(where: { $0.queueEntryID == currentEntry.id }) else {
                        clearQueueCorrelationAfterDivergedTransition()
                        return
                    }
                    didRecoverReissuedStart = true
                case .waiting:
                    return
                }
                activeSession = nil
                playbackIntended = true
                clearDeliveryFailure()
                currentPlaylistID = playlistID
                currentPlaylistScope = scope
                if let confirmedPlaybackOrder {
                    persistConfirmedPlaybackOrder(
                        confirmedPlaybackOrder,
                        playlistID: playlistID,
                        scope: scope
                    )
                }
                statusMessage = nil
                startMonitoring(context: context)
            },
            onUnconfirmed: {
                await restorePlayerQueueAfterUnconfirmedTransition(outgoing, context: context)
            }
        )

        switch result {
        case .confirmed:
            await refresh(context: context)
            await ArtworkCacheService.shared.touchPlaylistUsage(playlistID)
        case .diverged where didRecoverReissuedStart:
            await refresh(context: context)
            await ArtworkCacheService.shared.touchPlaylistUsage(playlistID)
        case .diverged:
            statusMessage = "Apple Music moved to a different track while replacing the queue."
            await refresh(context: context)
        case .failed(let error):
            await refresh(context: context)
            throw error
        case .timedOut:
            await refresh(context: context)
            throw PlaybackTransitionError.confirmationTimedOut
        case .rejected:
            throw PlaybackTransitionError.transitionInProgress
        }
    }

    func togglePlayPause(context: ModelContext) async {
        do {
            if player.playbackStatus == .playing {
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

        // The control renders from `isPlaying`, so when the player is playing
        // it shows a pause button. Its action has to agree, whatever Overplay
        // knows about queue correlation — routing this to playback would
        // restart the default playlist under a pause icon.
        if isPlaying {
            pause()
            return
        }

        await playCurrentOrDefault(settings: settings, context: context)
    }

    func playCurrentOrDefault(settings: OverplaySettings, context: ModelContext) async {
        // A queue the player is holding is resumed, not replaced — including
        // when Overplay has lost correlation and cannot describe it. Falling
        // through to the default playlist here would restart it from its
        // first track under a play button that meant "resume".
        if canControlPlayback || canSkipTracks {
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
        updateMusicKitNowPlayingTrack(currentEntry: player.currentEntry)
        publishNowPlayingMetadata(isPlaying: false)
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        await refresh(context: context)
        let outgoing = captureOutgoingPlaybackTransition()
        let result = await performPlayerConfirmedTransition(
            outgoingEntryID: outgoing.entryID,
            expectedEntryIDs: liveQueueEntryIDs,
            command: {
                try await player.skipToNextEntry()
            },
            onObservedTransition: { _ in
                evaluateOutgoingTransition(
                    outgoing,
                    settings: settings,
                    naturalCompletion: false,
                    context: context
                )
            }
        )

        switch result {
        case .confirmed, .diverged:
            await refresh(context: context)
        case .failed(let error):
            // The position below is read out of the mapped queue, so a
            // partially mapped one could make the current entry look like the
            // last entry while the live queue proves otherwise. Getting that
            // wrong persists a skip that never happened and swallows the
            // delivery failure that did.
            if isQueueCorrelationComplete || player.currentEntry == nil,
               PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
                   activeQueueIndex: activeQueueIndex,
                   activeQueueCount: activeQueueEntries.count,
                   hasCurrentEntry: player.currentEntry != nil,
                   isShuffling: shuffleEnabled
               ), outgoing.musicItemID != nil {
                // The queue really is exhausted. MusicKit owns repeat, so
                // whether anything plays next is its decision, not Overplay's.
                evaluateOutgoingTransition(
                    outgoing,
                    settings: settings,
                    naturalCompletion: false,
                    context: context
                )
                await refresh(context: context)
                return
            }
            await refresh(context: context)
            reportDeliveryFailure(message: musicPlaybackFailureMessage(for: error))
        case .timedOut:
            await refresh(context: context)
            statusMessage = PlaybackTransitionError.confirmationTimedOut.localizedDescription
        case .rejected:
            break
        }
    }

    func previous(context: ModelContext) async {
        await refresh(context: context)
        let outgoing = captureOutgoingPlaybackTransition()
        let result = await performPlayerConfirmedTransition(
            outgoingEntryID: outgoing.entryID,
            expectedEntryIDs: liveQueueEntryIDs,
            command: {
                try await player.skipToPreviousEntry()
            },
            onObservedTransition: { _ in
                markActiveSessionEvaluatedWithoutSkip(outgoing)
            }
        )

        switch result {
        case .confirmed, .diverged:
            await refresh(context: context)
        case .failed(let error):
            await refresh(context: context)
            statusMessage = error.localizedDescription
        case .timedOut:
            await refresh(context: context)
            statusMessage = PlaybackTransitionError.confirmationTimedOut.localizedDescription
        case .rejected:
            break
        }
    }

    func toggleShuffle(context: ModelContext) async {
        await setShuffleEnabled(!shuffleEnabled, context: context)
    }

    /// A mode change, not a rebuild. MusicKit shuffles the queue it already
    /// holds, so nothing is reordered, requeued or restarted.
    func setShuffleEnabled(_ isEnabled: Bool, context: ModelContext) async {
        player.shuffleMode = isEnabled ? .songs : .off
        playbackModeVersion += 1
        await refresh(context: context)
    }

    /// Keeps Overplay's repeat control intentionally binary: off or repeat all.
    func toggleRepeatAll(context: ModelContext) async {
        await setRepeatMode(repeatAllEnabled ? MusicPlayer.RepeatMode.none : .all, context: context)
    }

    func setRepeatMode(_ mode: MusicPlayer.RepeatMode, context: ModelContext) async {
        player.repeatMode = mode
        playbackModeVersion += 1
        await refresh(context: context)
    }

    /// Kept for the remote shuffle command, which asks for shuffle rather
    /// than for a new order.
    @discardableResult
    func reshuffleCurrentPlaylist(context: ModelContext) async -> Bool {
        guard currentPlaylistID != nil else {
            statusMessage = "Choose a playlist first."
            return false
        }

        await setShuffleEnabled(true, context: context)
        return true
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

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
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
            isPlaying = player.playbackStatus == .playing
            publishNowPlayingMetadata(isPlaying: isPlaying)
            return
        }

        let oldTrackID = activeSession?.trackID
        let oldLocalTrackID = activeSession?.localTrackID
        let oldCurrentItemLocalTrackID = currentPlaylistItem?.trackID.uuidString
        let oldActiveQueueLocalTrackID = activeQueueCurrentLocalTrackID
        let currentPlayerEntry = player.currentEntry
        updateLivePlayerEntryState(hasEntry: currentPlayerEntry != nil)
        updateMusicKitNowPlayingTrack(currentEntry: currentPlayerEntry)
        observePlaybackModeChanges()
        correlateAppendedEntries()
        recorrelateLiveQueueIfNeeded(currentEntry: currentPlayerEntry, context: context)
        let identity = resolvedCurrentPlaybackIdentity(context: context)
        let hasUnresolvedConcretePlayerEntry = player.currentEntry != nil && identity == nil
        // MusicKit can report an entry before its item is available. Hold the
        // current belief while it hydrates instead of tearing playback state
        // down on one observation.
        unresolvedEntryState = PlaybackUnresolvedEntryPolicy.assess(
            unresolvedEntryState,
            hasUnresolvedConcreteEntry: hasUnresolvedConcretePlayerEntry && !isAwaitingOwnQueueHydration
        )
        let hasDivergedUnresolvedPlayerEntry = unresolvedEntryState.hasDiverged
        let hasUncorrelatedConcretePlayerEntry = player.currentEntry != nil
            && identity?.isQueueCorrelated == false
        let newTrackID = identity?.musicItemID
        let newLocalTrackID = identity?.localTrackID
        let currentPlaybackTime = player.playbackTime
        elapsedSeconds = currentPlaybackTime
        isPlaying = player.playbackStatus == .playing

        // Queue end never surfaces as a nil resolved identity, because
        // identity resolution falls back to the cached active queue entry
        // and session. Detect it from the player state directly, and only
        // restart when the outgoing session was observed near its end so an
        // external stop mid-track cannot trigger a surprise restart.
        let queueDidEnd = PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: player.currentEntry != nil,
            playbackStatus: player.playbackStatus,
            hasActiveQueue: !activeQueueEntries.isEmpty,
            isRestartingQueue: false
        )
        if queueDidEnd {
            let queueEndLocalTrackID = oldLocalTrackID
                ?? oldCurrentItemLocalTrackID
                ?? oldActiveQueueLocalTrackID
            // `queueDidEnd` is a state, not an edge: no current entry while
            // stopped stays true every tick until something changes it. Record
            // once per queue end, reusing the flag that already exists to
            // edge-trigger the neighbouring diagnostic below.
            let endedNaturally = oldTrackID != nil
                && PlaybackQueueEndPolicy.shouldRestartAfterQueueEnd(session: activeSession)
            let isNewQueueEnd = !didHandleQueueEnd
            didHandleQueueEnd = true
            if isNewQueueEnd {
                MusicKitActivityLog.shared.record(
                    .queueEndObserved,
                    detail: endedNaturally ? "played out" : "stopped mid-track"
                )
            }
            if endedNaturally {
                playbackIntended = false
                if let oldTrackID, isNewQueueEnd {
                    // The last track finished. Credit it, then stop: MusicKit
                    // owns repeat, so whether anything plays next is its
                    // decision. Later observations of the same ended state
                    // remain a clean stop rather than becoming a stall.
                    TrackMetadataDiagnostics.log(
                        "queue ended naturally status=\(player.playbackStatus) lastTrackID=\(oldTrackID) lastLocalTrackID=\(queueEndLocalTrackID ?? "nil")"
                    )
                    didLogQueueEndWithoutRestart = false
                    if let settings = monitoredSettings(context: context) {
                        evaluateActiveSession(
                            settings: settings,
                            context: context,
                            naturalCompletion: true,
                            elapsedSeconds: activeSession?.lastObservedPlaybackTime,
                            durationSeconds: activeSession?.durationSeconds,
                            fallbackLocalTrackID: queueEndLocalTrackID
                        )
                    }
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
            didHandleQueueEnd = false
        }

        let didChangeTrack = playbackIdentityDidChange(
            oldTrackID: oldTrackID,
            oldLocalTrackID: oldLocalTrackID,
            newTrackID: newTrackID,
            newLocalTrackID: newLocalTrackID,
            context: context
        )

        if didChangeTrack, let settings = monitoredSettings(context: context) {
            evaluateActiveSession(
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

        if hasUncorrelatedConcretePlayerEntry,
           identity.map({ !isAwaitingAppendCorrelation($0) }) ?? true {
            // A concrete MusicKit entry outside the realized queue is the
            // authority, but it cannot inherit the outgoing playlist row or
            // restoration identity. Preserve the resolved item below while
            // dropping every stale queue-specific correlation first.
            clearQueueCorrelationAfterDivergedTransition()
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
        } else if hasDivergedUnresolvedPlayerEntry {
            // Correlation is gone for good, so this is the last moment
            // anything can say what the outgoing track played. Credit it
            // before its session goes with the rest: the alternative is that
            // a track which played out in full is never counted at all.
            // `hasEvaluated` makes this a no-op when it was already judged.
            if let settings = monitoredSettings(context: context) {
                evaluateActiveSession(
                    settings: settings,
                    context: context,
                    naturalCompletion: false,
                    elapsedSeconds: activeSession?.lastObservedPlaybackTime,
                    durationSeconds: activeSession?.durationSeconds,
                    fallbackLocalTrackID: oldLocalTrackID
                        ?? oldCurrentItemLocalTrackID
                        ?? oldActiveQueueLocalTrackID
                )
            }
            // Entry-level correlation is genuinely gone, but Overplay still
            // knows which playlist and track it started. Keep that and the
            // durable restore state: clearing them leaves every surface
            // unable to describe or pause playback that is still running.
            clearQueueCorrelationPreservingPlayback()
        } else if currentTrack != nil || currentPlaylistID != nil {
            // Deliberately leaves the session's observed progress alone. The
            // only way to reach here holding a live session is a concrete
            // player entry Overplay cannot resolve, so `player.playbackTime`
            // is that entry's position and not the session's. Folding it in
            // rewound the outgoing track's evidence to the incoming track's
            // 0s, so a play that completed was later credited as a skip at
            // the start of the track.
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
            resetAppendedQueueCorrelations()
            currentPlaylistID = nil
            currentPlaylistScope = .active
            activePlaylistSnapshot = nil
            prefetchedArtworkTrackID = nil
            // Nothing is playing, so the held-back tail describes no queue.
            // Left in place it would retain the whole decoded playlist.
        }

        logPlaybackRefreshIfNeeded(identity: identity)
        publishNowPlayingMetadata(isPlaying: isPlaying)
        if currentPlaylistID == nil {
            activePlaylistSnapshot = nil
        } else if !activePlaylistSnapshotNeedsRebuild,
                  let activePlaylistSnapshot,
                  activePlaylistSnapshot.musicPlaylistID == currentPlaylistID,
                  activePlaylistSnapshot.playbackScope == currentPlaylistScope {
            updateActivePlaylistSnapshotCurrentRow()
        } else {
            rebuildActivePlaylistSnapshot(context: context)
        }

        if let newTrackID {
            persistLocalPlaybackState(musicItemID: newTrackID, localTrackID: newLocalTrackID)
        }

        await trackDeliveryHealth(
            status: player.playbackStatus,
            hasCurrentEntry: player.currentEntry != nil,
            playbackTime: currentPlaybackTime
        )
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
        // The remote-delete target must derive from the evicted item itself;
        // currentTrack is a last resort, and only when the item is verified
        // to be the displayed one — resolving from currentTrack first could
        // ask Apple Music to delete the wrong track if this ever runs for a
        // non-displayed item.
        let itemTrack = try? TrackRecordRepository.track(id: item.trackID, in: context)
        let trackID = itemTrack?.catalogID
            ?? itemTrack?.libraryID
            ?? (currentPlaylistItem?.id == item.id ? currentTrack?.id : nil)
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
    ) {
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
            patchActivePlaylistSnapshotRow(for: outcome.item, context: context)
        }
    }

    /// An evaluation outcome mutates a single item's counters, and this
    /// runs on every counted skip/playthrough — patch that row instead of
    /// refetching the whole playlist. Falls back to a full rebuild when the
    /// snapshot doesn't match the current playlist/scope or the item's
    /// membership changed.
    private func patchActivePlaylistSnapshotRow(for item: PlaylistItemRecord?, context: ModelContext) {
        guard let item,
              let activePlaylistSnapshot,
              activePlaylistSnapshot.musicPlaylistID == currentPlaylistID,
              activePlaylistSnapshot.playbackScope == currentPlaylistScope,
              let patched = activePlaylistSnapshot.updatingRow(for: item) else {
            rebuildActivePlaylistSnapshot(context: context)
            return
        }

        self.activePlaylistSnapshot = patched
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
            queueItem: player.currentEntryItem,
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
        if let queueEntry = player.currentEntry {
            let queueReportedTrackID = player.currentEntryItem?.id.rawValue
            if let realizedEntry = activeQueueEntries.first(where: { $0.queueEntryID == queueEntry.id }) {
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

            // A concrete but not-yet-decodable player entry is still
            // authoritative. Do not let the cached active queue disguise it
            // as the previously correlated entry while MusicKit hydrates it.
            return nil
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

    private func logQueueEndWithoutRestartIfNeeded() {
        guard !didLogQueueEndWithoutRestart else { return }
        didLogQueueEndWithoutRestart = true
        let sessionDescription = activeSession.map {
            "\($0.trackID)@\(String(format: "%.1f", $0.lastObservedPlaybackTime))/\($0.durationSeconds.map { String(format: "%.1f", $0) } ?? "nil")"
        } ?? "nil"
        TrackMetadataDiagnostics.log(
            "queue ended without restart status=\(player.playbackStatus) session=\(sessionDescription)"
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
            queueItem: player.currentEntryItem,
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

    /// Adopts appended entries as the player reports item IDs for them.
    ///
    /// Only the leading run that correlated is taken, so `activeQueueEntries`
    /// cannot fall out of the player's order while hydration completes
    /// piecemeal.
    private func correlateAppendedEntries() {
        guard !appendedUncorrelatedEntries.isEmpty,
              playerStillHoldsOverplayQueue() else {
            return
        }

        let realizedEntries = PlaybackQueueSnapshotCorrelator.realizedEntries(
            expected: appendedUncorrelatedEntries,
            snapshots: player.queueEntrySnapshots,
            reservedEntryIDs: Set(activeQueueEntries.map(\.queueEntryID))
        )
        let correlatedLocalTrackIDs = Set(realizedEntries.map(\.localTrackID))
        let leadingRun = appendedUncorrelatedEntries.prefix {
            correlatedLocalTrackIDs.contains($0.localTrackID)
        }
        guard !leadingRun.isEmpty else { return }

        let adopted = Set(leadingRun.map(\.localTrackID))
        activeQueueEntries.append(
            contentsOf: realizedEntries.filter { adopted.contains($0.localTrackID) }
        )
        appendedUncorrelatedEntries.removeFirst(leadingRun.count)
    }

    private func updateLivePlayerEntryState(hasEntry: Bool) {
        if hasLivePlayerEntry != hasEntry {
            hasLivePlayerEntry = hasEntry
        }
    }

    /// Rebuilds entry-level correlation from the queue the player is holding.
    ///
    /// MusicKit owns shuffle and repeat now, and a mode change reorders — and
    /// can re-materialize — the queue it is holding. Overplay minted the
    /// entry IDs it started with, so once those are gone every tick reads as
    /// a diverged transition and drops the playlist, the queue and the
    /// durable restore point. That is what disables Next and Previous and
    /// stops every play and skip being counted, for a queue still playing
    /// exactly the playlist Overplay asked for.
    ///
    /// Runs whenever the live queue holds an entry that has an item and is
    /// not mapped yet, which covers three separate situations with one
    /// mechanism:
    ///
    /// - the player re-issued every entry ID;
    /// - a re-materialized queue hydrated one entry at a time, so entries
    ///   omitted by an earlier rebuild can be merged in as they arrive
    ///   rather than staying absent until they become current;
    /// - the current entry has not hydrated at all, in which case the
    ///   entries that have are still enough to prove the player is holding
    ///   Overplay's queue. That proof is what keeps
    ///   `isAwaitingOwnQueueHydration` true, and so keeps the outgoing
    ///   session alive to be credited once the current entry resolves.
    ///
    /// A hydrated current entry that is not a member of the current playlist
    /// is refused, so a genuine external takeover still reads as divergence.
    private func recorrelateLiveQueueIfNeeded(
        currentEntry: MusicPlayer.Queue.Entry?,
        context: ModelContext
    ) {
        guard let currentPlaylistID,
              appendedUncorrelatedEntries.isEmpty || !playerStillHoldsOverplayQueue() else {
            return
        }

        let snapshots = player.queueEntrySnapshots
        let mappedEntryIDs = Set(activeQueueEntries.map(\.queueEntryID))
        let mappableEntryIDs = snapshots.filter { snapshot in
            snapshot.musicItemID != nil
                && !mappedEntryIDs.contains(snapshot.id)
                && !unmappableLiveEntryIDs.contains(snapshot.id)
        }
        guard !mappableEntryIDs.isEmpty,
              let members = try? currentPlaylistQueueMembers(
                  playlistID: currentPlaylistID,
                  context: context
              ) else {
            return
        }

        let realizedEntries = PlaybackQueueSnapshotCorrelator.realizedEntriesInPlayerOrder(
            snapshots: snapshots,
            members: members
        )
        let realizedEntryIDs = Set(realizedEntries.map(\.queueEntryID))
        // Remember what could be read and still did not belong, so a queue
        // holding foreign entries does not re-read the whole playlist on
        // every tick. Anything that has not hydrated is left out: it has not
        // been judged yet.
        unmappableLiveEntryIDs = Set(
            snapshots
                .filter { $0.musicItemID != nil && !realizedEntryIDs.contains($0.id) }
                .map(\.id)
        )

        // Nothing in the player's queue belongs to this playlist, or the
        // entry it is actually playing does not. Either way this is not
        // Overplay's queue to adopt.
        guard !realizedEntries.isEmpty else { return }
        if let currentEntry,
           player.currentEntryItem != nil,
           !realizedEntryIDs.contains(currentEntry.id) {
            return
        }
        guard realizedEntryIDs != mappedEntryIDs else { return }

        // Keep the cursor on the outgoing track when the current entry has
        // not hydraded far enough to place it. It is a correlation cursor,
        // and the outgoing track is still Overplay's best belief until the
        // player says otherwise.
        let outgoingLocalTrackID = activeQueueCurrentLocalTrackID
            ?? currentPlaylistItem?.trackID.uuidString
            ?? activeSession?.localTrackID
        let index = realizedEntries.firstIndex { $0.queueEntryID == currentEntry?.id }
            ?? outgoingLocalTrackID.flatMap { localTrackID in
                realizedEntries.firstIndex { $0.localTrackID == localTrackID }
            }

        // Facts rather than an interpretation: `retained` is how many of the
        // entry IDs Overplay had mapped are still in the player's queue, so
        // zero against a non-empty previous map is a full re-issue, and a
        // non-zero one is piecemeal hydration being merged.
        let retainedMappedEntryCount = mappedEntryIDs
            .intersection(snapshots.map(\.id))
            .count
        MusicKitActivityLog.shared.record(
            .queueCorrelationRebuilt,
            magnitude: Double(realizedEntries.count),
            detail: "live=\(snapshots.count) mapped=\(realizedEntries.count) wasMapped=\(mappedEntryIDs.count) retained=\(retainedMappedEntryCount)"
        )
        TrackMetadataDiagnostics.log(
            "queue correlation rebuilt from the live player queue entries=\(realizedEntries.count) live=\(snapshots.count) index=\(index.map(String.init) ?? "nil") unmappable=\(unmappableLiveEntryIDs.count)"
        )
        resetAppendedQueueCorrelations()
        activeQueueEntries = realizedEntries
        activeQueueIndex = index
    }

    /// True while the mapped queue covers every entry the player is holding.
    ///
    /// A rebuild can only map the entries the player has hydrated, so the
    /// mapped queue is legitimately a subset of the live one. Anything that
    /// reads a *position* out of it has to know that.
    private var isQueueCorrelationComplete: Bool {
        let mappedEntryIDs = Set(activeQueueEntries.map(\.queueEntryID))
        let snapshots = player.queueEntrySnapshots
        guard !snapshots.isEmpty else { return false }
        return snapshots.allSatisfy { mappedEntryIDs.contains($0.id) }
    }

    /// Every track of the current playlist, as something the live player
    /// queue can be matched against. Not filtered by playback scope: the
    /// queue holds what it holds, and a track retired mid-queue must still
    /// correlate to the row it came from.
    private func currentPlaylistQueueMembers(
        playlistID: String,
        context: ModelContext
    ) throws -> [PendingQueueCorrelation] {
        let inputs = try PlaybackQueueOrchestrator.playlistInputs(for: playlistID, in: context)
        return inputs.items.compactMap { item in
            guard let track = inputs.tracksByID[item.trackID] else { return nil }
            let musicItemIDs = PlaybackQueueBuilder.musicItemIDs(for: track)
            guard let queuedMusicItemID = musicItemIDs.first else { return nil }

            return PendingQueueCorrelation(
                playlistItemID: item.id,
                localTrackID: item.trackID.uuidString,
                queuedMusicItemID: queuedMusicItemID,
                matchableMusicItemIDs: Set(musicItemIDs)
            )
        }
    }

    /// Whether an uncorrelated player entry is one Overplay appended and is
    /// still waiting to correlate. That is not divergence, and treating it as
    /// such discards the playlist, the queue and the durable restore point for
    /// a queue playing exactly what Overplay asked for.
    private func isAwaitingAppendCorrelation(_ identity: CurrentPlaybackIdentity) -> Bool {
        guard playerStillHoldsOverplayQueue() else { return false }

        return appendedUncorrelatedEntries.contains { member in
            member.matches(identity.musicItemID)
                || (identity.localTrackID.map { $0 == member.localTrackID } ?? false)
        }
    }

    /// Whether any entry Overplay handed the player is still in its live
    /// queue. This prevents a same-song external takeover from inheriting a
    /// pending append correlation after Overplay's queue has disappeared.
    private func playerStillHoldsOverplayQueue() -> Bool {
        guard !activeQueueEntries.isEmpty else { return false }

        let liveEntryIDs = Set(player.queueEntrySnapshots.map(\.id))
        return activeQueueEntries.contains { liveEntryIDs.contains($0.queueEntryID) }
    }

    /// A current entry without an item is expected while MusicKit is still
    /// hydrating a queue member Overplay appended itself. It must not age into
    /// divergence while the rest of Overplay's queue is demonstrably live.
    ///
    /// A queue the player re-materialized hydrates the same way, entry by
    /// entry, and correlation can only map the entries that have arrived. An
    /// unresolvable current entry while any live entry is still without an
    /// item is that hydration in progress, not divergence — ageing it into
    /// divergence discards the active session before the outgoing track has
    /// been credited.
    private var isAwaitingOwnQueueHydration: Bool {
        guard playerStillHoldsOverplayQueue() else { return false }
        guard appendedUncorrelatedEntries.isEmpty else { return true }
        let mappedEntryIDs = Set(activeQueueEntries.map(\.queueEntryID))
        return player.queueEntrySnapshots.contains { snapshot in
            snapshot.musicItemID == nil && !mappedEntryIDs.contains(snapshot.id)
        }
    }

    /// MusicKit owns shuffle and repeat, and `MusicPlayer.State` is not
    /// observable, so a change made from the Lock Screen, Control Center,
    /// Siri or the Music app reaches Overplay only by being noticed here.
    /// Without this, `PLAY-004` holds only for changes Overplay made itself.
    private func observePlaybackModeChanges() {
        let reportedShuffle = player.reportedShuffleMode
        let reportedRepeat = player.reportedRepeatMode
        let shuffle = player.shuffleMode
        let repeatMode = player.repeatMode
        let effectiveModeChanged = shuffle != lastObservedShuffleMode || repeatMode != lastObservedRepeatMode
        let reportedModeChanged = reportedShuffle != lastReportedShuffleMode
            || reportedRepeat != lastReportedRepeatMode
        guard !hasObservedPlaybackModes || effectiveModeChanged || reportedModeChanged else {
            return
        }

        let isFirstObservation = !hasObservedPlaybackModes
        let previousReportedShuffle = lastReportedShuffleMode
        let previousReportedRepeat = lastReportedRepeatMode
        let previousShuffle = lastObservedShuffleMode
        let previousRepeat = lastObservedRepeatMode
        hasObservedPlaybackModes = true
        lastReportedShuffleMode = reportedShuffle
        lastReportedRepeatMode = reportedRepeat
        lastObservedShuffleMode = shuffle
        lastObservedRepeatMode = repeatMode
        guard !isFirstObservation else { return }

        MusicKitActivityLog.shared.record(
            .playerModeObserved,
            detail: "rawShuffle=\(Self.modeDescription(previousReportedShuffle))->\(Self.modeDescription(reportedShuffle)) "
                + "effectiveShuffle=\(previousShuffle.map(String.init(describing:)) ?? "nil")->\(shuffle) "
                + "rawRepeat=\(Self.modeDescription(previousReportedRepeat))->\(Self.modeDescription(reportedRepeat)) "
                + "effectiveRepeat=\(previousRepeat.map(String.init(describing:)) ?? "nil")->\(repeatMode)"
        )
        if effectiveModeChanged {
            playbackModeVersion += 1
        }
    }

    private static func modeDescription<T>(_ mode: T?) -> String {
        mode.map(String.init(describing:)) ?? "nil"
    }

    private func updateMusicKitNowPlayingTrack(currentEntry: MusicPlayer.Queue.Entry?) {
        guard let currentEntry else {
            if musicKitNowPlayingTrack != nil {
                musicKitNowPlayingTrack = nil
            }
            musicKitNowPlayingEntryID = nil
            if isMusicKitNowPlayingTrackPending {
                isMusicKitNowPlayingTrackPending = false
            }
            return
        }

        guard let track = PlaybackTrackResolver.currentPlaybackTrack(
            from: player.currentEntryItem,
            playlistID: currentPlaylistID
        ) else {
            // The player has made an entry current whose item it has not
            // hydrated. Apple Music can leave it that way for as long as
            // Overplay is not the app in front — another CarPlay app on the
            // screen, say — so this is not a blip that can be waited out.
            guard activeQueueEntries.contains(where: { $0.queueEntryID == currentEntry.id }) else {
                // Nothing describes this entry. Publish nothing for it.
                if musicKitNowPlayingTrack != nil {
                    musicKitNowPlayingTrack = nil
                    musicKitNowPlayingEntryID = nil
                }
                if !isMusicKitNowPlayingTrackPending {
                    isMusicKitNowPlayingTrackPending = true
                }
                return
            }

            // Overplay queued this entry, so its own record already names the
            // track: hand the display to `currentTrack` rather than holding a
            // pending state. Continuing to publish the outgoing entry until
            // Apple Music hydrates the item is what left the whole iPhone Now
            // Playing screen bound to the previous track while CarPlay showed
            // navigation.
            if musicKitNowPlayingEntryID != currentEntry.id, musicKitNowPlayingTrack != nil {
                musicKitNowPlayingTrack = nil
                musicKitNowPlayingEntryID = nil
            }
            if isMusicKitNowPlayingTrackPending {
                isMusicKitNowPlayingTrackPending = false
            }
            return
        }

        if musicKitNowPlayingTrack != track {
            musicKitNowPlayingTrack = track
        }
        musicKitNowPlayingEntryID = currentEntry.id
        if isMusicKitNowPlayingTrackPending {
            isMusicKitNowPlayingTrackPending = false
        }
    }

    private func refreshCurrentPlaybackMetadata(context: ModelContext) {
        guard let musicItemID = currentTrack?.id else { return }
        syncPlaybackMetadata(for: musicItemID, context: context)
    }

    private func markActiveSessionEvaluatedWithoutSkip(_ outgoing: OutgoingPlaybackTransition) {
        activeSession = PlaybackSessionEvaluationService.markEvaluatedWithoutSkip(
            activeSession: activeSession,
            currentTrackID: outgoing.musicItemID,
            localTrackID: outgoing.localTrackID,
            elapsedSeconds: outgoing.elapsedSeconds,
            durationSeconds: outgoing.durationSeconds
        )
    }

    private func bumpPlaybackItemMetadataVersion() {
        knownMusicItemIDsCache = nil
        unresolvableMusicItemIDs.removeAll()
        unmappableLiveEntryIDs.removeAll()
        playbackItemMetadataVersion += 1
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

    /// A queue replacement changed the live player before confirmation. The
    /// stored order was deliberately not overwritten, so rebuild that queue,
    /// restore its position/play intent, and re-correlate the realized IDs.
    private func restorePlayerQueueAfterUnconfirmedTransition(
        _ outgoing: OutgoingPlaybackTransition,
        context: ModelContext
    ) async {
        guard let currentPlaylistID else {
            player.pause()
            clearQueueCorrelationAfterDivergedTransition()
            return
        }
        guard let entries = try? PlaybackQueueOrchestrator.orderedCachedQueueEntries(
            for: currentPlaylistID,
            playerID: playerID,
            startingTrackID: outgoing.localTrackID,
            scope: currentPlaylistScope,
            in: context
        ), !entries.isEmpty else {
            clearQueueCorrelationAfterDivergedTransition()
            return
        }

        let materialization = PlaybackQueueMaterializer.materialize(
            entries,
            startingAt: outgoing.localTrackID
        )
        player.replaceQueue(with: materialization)
        player.playbackTime = outgoing.elapsedSeconds
        if outgoing.wasPlaying {
            try? await player.play()
        } else {
            player.pause()
        }

        let expectedEntryIDs = Set(materialization.realizedEntries.map(\.queueEntryID))
        if await waitForPlayerEntry(in: expectedEntryIDs) {
            updateActiveQueue(
                realizedEntries: materialization.realizedEntries,
                startingAt: outgoing.localTrackID
            )
        } else {
            clearQueueCorrelationAfterDivergedTransition()
        }
    }

    private func waitForPlayerEntry(in expectedEntryIDs: Set<String>) async -> Bool {
        let observationCount = max(transitionConfirmationPolicy.maximumObservationCount, 1)
        for observationIndex in 0..<observationCount {
            if let entryID = player.currentEntry?.id,
               expectedEntryIDs.contains(entryID) {
                return true
            }
            if observationIndex < observationCount - 1 {
                await sleepForTransitionConfirmation(transitionConfirmationPolicy.observationInterval)
            }
        }
        return false
    }

    private func persistConfirmedPlaybackOrder(
        _ orderedTrackIDs: [String],
        playlistID: String,
        scope: PlaylistPlaybackScope
    ) {
        PlaybackQueueOrchestrator.persistReshuffledOrder(
            orderedTrackIDs,
            playlistID: playlistID,
            playerID: playerID,
            scope: scope
        )
        playbackModeVersion += 1
        activePlaylistSnapshotNeedsRebuild = true
    }

    private func trackDeliveryHealth(
        status: MusicPlayer.PlaybackStatus,
        hasCurrentEntry: Bool,
        playbackTime: Double
    ) async {
        if status == .interrupted {
            // MusicKit and the system own both the interruption and whether
            // playback resumes afterward. Never expose it as a delivery
            // failure or let it inherit a prior stall's automatic recovery.
            deliveryInterruptionGeneration += 1
            deliveryStallState = PlaybackDeliveryStallPolicy.State()
            clearDeliveryFailure(refillRecoveryBudget: false)
            return
        }

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
            // Surfaced failures clear on the first good tick so the UI is
            // not left lying, but the recovery budget only refills once
            // delivery has stayed healthy — see the policy for why.
            clearDeliveryFailure(refillRecoveryBudget: deliveryStallState.hasRecoveredFromStall)
            return
        }

        guard deliveryStallState.isStalled else { return }

        if !isDeliveryStalled {
            reportDeliveryFailure(message: Self.deliveryStallMessage)
            TrackMetadataDiagnostics.log(
                "playback delivery stalled status=\(status) time=\(String(format: "%.1f", playbackTime)) frozen=\(deliveryStallState.frozenTicks)"
            )
        }

        await MusicKitActivityLog.shared.withOrigin(.automatic) {
            await attemptDeliveryRecoveryIfNeeded()
        }
    }

    private func attemptDeliveryRecoveryIfNeeded() async {
        guard !isAttemptingDeliveryRecovery,
              player.playbackStatus == .playing,
              PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
                  state: deliveryStallState,
                  playbackIntended: playbackIntended,
                  isNetworkReachable: isNetworkReachable(),
                  attemptsMade: deliveryRecoveryAttempts
              ) else {
            return
        }

        let interruptionGeneration = deliveryInterruptionGeneration
        isAttemptingDeliveryRecovery = true
        defer { isAttemptingDeliveryRecovery = false }
        deliveryRecoveryAttempts += 1
        let attempt = deliveryRecoveryAttempts
        MusicKitActivityLog.shared.record(
            .playbackRecoveryAttempt,
            magnitude: Double(attempt),
            detail: "attempt \(attempt) frozen=\(deliveryStallState.frozenTicks)",
            notes: [.automaticRetry]
        )
        do {
            try await player.prepareToPlay()
            guard player.playbackStatus == .playing,
                  deliveryInterruptionGeneration == interruptionGeneration else {
                deliveryStallState = PlaybackDeliveryStallPolicy.State()
                clearDeliveryFailure(refillRecoveryBudget: false)
                return
            }
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
        // Only on the edge: a stall that persists would otherwise fill the
        // log with the same line every tick.
        if !isDeliveryStalled {
            MusicKitActivityLog.shared.record(.deliveryStallDetected, detail: message)
        }
        isDeliveryStalled = true
        statusMessage = message
    }

    private func clearDeliveryFailure(refillRecoveryBudget: Bool = true) {
        if refillRecoveryBudget {
            deliveryRecoveryAttempts = 0
        }
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
        guard let queueEntry = player.currentEntry else { return nil }
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

    /// Publishes durable playlist-item changes recovered while Overplay was
    /// suspended through the same controller snapshot used by live playback.
    /// The observation may have completed in a different SwiftData context,
    /// so fetch the affected rows in this context instead of relying on query
    /// invalidation to refresh the active surfaces later.
    func publishReconciledPlaylistItemChanges(
        localTrackIDs: [String],
        playlistID: String,
        context: ModelContext
    ) {
        guard currentPlaylistID == playlistID, !localTrackIDs.isEmpty,
              let playlist = try? currentPlaylist(in: context) else {
            return
        }

        let changedTrackIDs = Set(localTrackIDs.compactMap(UUID.init(uuidString:)))
        guard !changedTrackIDs.isEmpty,
              let playlistItems = try? PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context) else {
            return
        }
        let changedItems = playlistItems.filter { changedTrackIDs.contains($0.trackID) }
        guard !changedItems.isEmpty else { return }

        let displayedLocalTrackID = nowPlayingDisplayLocalTrackID
        if let displayedItem = changedItems.first(where: { $0.trackID.uuidString == displayedLocalTrackID }),
           let musicItemID = currentTrack?.id {
            currentPlaylistItem = displayedItem
            syncPlaybackMetadata(
                for: musicItemID,
                trustedPlaylistItem: displayedItem,
                context: context
            )
            persistLocalPlaybackState(
                musicItemID: musicItemID,
                localTrackID: displayedItem.trackID.uuidString
            )
            publishNowPlayingMetadata(isPlaying: isPlaying)
        }

        guard var snapshot = activePlaylistSnapshot,
              snapshot.musicPlaylistID == playlistID,
              snapshot.playbackScope == currentPlaylistScope else {
            rebuildActivePlaylistSnapshot(context: context)
            return
        }

        for item in changedItems {
            guard let patched = snapshot.updatingRow(for: item) else {
                rebuildActivePlaylistSnapshot(context: context)
                return
            }
            snapshot = patched
        }
        activePlaylistSnapshot = snapshot
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
    func reconcileStoredOrder(for requestedPlaylist: PlaylistRecord, context: ModelContext) {
        // Membership changed (sync, link change, manual add): previously
        // unresolvable music item IDs may now have records.
        unresolvableMusicItemIDs.removeAll()
        do {
            // Triage sources retain their own remote-sync bookkeeping, but
            // every item they contribute belongs to the shared bucket. All
            // playback surfaces therefore reconcile the bucket, never the
            // inert source record.
            let playlist = requestedPlaylist.role == .triageSource
                ? try PlaylistRepository.triageBucket(in: context)
                : requestedPlaylist
            let isCurrentPlaylist = currentPlaylistID == playlist.musicPlaylistID
            let isCurrentActivePlaylist = isCurrentPlaylist && currentPlaylistScope == .active
            let currentLocalTrackID = isCurrentActivePlaylist
                ? currentPlaylistItem?.trackID.uuidString
                : nil
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let activeItems = items.filter { PlaylistPlaybackScope.active.includes($0) }
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: activeItems)
            let previousState = PlaybackOrderStore.state(
                playerID: playerID,
                musicPlaylistID: PlaylistPlaybackScope.active.playbackOrderPlaylistID(for: playlist.musicPlaylistID)
            )
            let playableOrder = PlaybackOrderEngine.normalOrder(for: orderTracks, includeUnplayableTrackID: currentLocalTrackID)
            let reconciledOrder: [String]
            if isCurrentActivePlaylist,
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
            }

            // Sync reconciliation may already have appended new rows to the
            // stored order. Compare against the live and pending queue instead
            // so that equality with the store cannot hide a required append.
            if isCurrentActivePlaylist {
                let previouslyPublishedTrackIDs = activePlaylistSnapshot.flatMap { snapshot in
                    snapshot.musicPlaylistID == playlist.musicPlaylistID
                        && snapshot.playbackScope == .active
                        ? Set(snapshot.rows.map(\.localTrackID))
                        : nil
                }
                let knownLiveTrackIDs = Set(
                    activeQueueEntries.map(\.localTrackID)
                        + appendedUncorrelatedEntries.map(\.localTrackID)
                        + reconciliationPendingAppendTrackIDs
                )
                // A re-materialized MusicKit queue can be only partially
                // hydrated, so `activeQueueEntries` may temporarily omit
                // tracks that are already live. In that window, only rows
                // absent from the last published playlist snapshot are
                // proven additions. Once hydration completes, the live queue
                // is authoritative again and can recover any failed append.
                let appendedIDs = if isAwaitingOwnQueueHydration {
                    previouslyPublishedTrackIDs.map { publishedTrackIDs in
                        reconciledOrder.filter {
                            !publishedTrackIDs.contains($0) && !knownLiveTrackIDs.contains($0)
                        }
                    } ?? []
                } else {
                    reconciledOrder.filter { !knownLiveTrackIDs.contains($0) }
                }
                if !appendedIDs.isEmpty {
                    reconciliationPendingAppendTrackIDs.formUnion(appendedIDs)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.reconciliationPendingAppendTrackIDs.subtract(appendedIDs) }
                        await self.appendLiveQueueEntries(
                            localTrackIDs: appendedIDs,
                            playlistID: playlist.musicPlaylistID,
                            context: context
                        )
                    }
                }
            }

            // Row metadata and provenance can change without changing order.
            // Rebuild the shared snapshot on every current-playlist
            // reconciliation so SwiftUI and CarPlay publish the sync result.
            if isCurrentPlaylist {
                rebuildActivePlaylistSnapshot(context: context)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Keeps a live queue attached when selecting a new One True Playlist
    /// demotes the playlist currently playing and reparents its rows into the
    /// triage bucket. The MusicKit queue itself is unchanged; only Overplay's
    /// playlist and item correlation needs to follow the moved records.
    func reconcilePlaylistSelection(context: ModelContext) {
        guard let previousMusicPlaylistID = currentPlaylistID,
              let previousPlaylist = try? PlaylistRepository.playlist(
                musicPlaylistID: previousMusicPlaylistID,
                in: context
              ),
              previousPlaylist.role == .triageSource,
              let bucket = try? PlaylistRepository.existingTriageBucket(in: context) else {
            return
        }

        let bucketItems: [PlaylistItemRecord]
        do {
            bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let itemsByTrackID = bucketItems.firstValueDictionary(keyedBy: \.trackID)

        LocalPlaybackStateStore.rekeyMusicPlaylistID(
            from: previousMusicPlaylistID,
            to: bucket.musicPlaylistID,
            flushImmediately: true
        )
        PlaybackIdentityStore.mergeMusicPlaylistID(
            from: previousMusicPlaylistID,
            into: bucket.musicPlaylistID,
            playerID: playerID,
            flushImmediately: true
        )
        mergePlaybackOrdersAfterDemotion(
            from: previousMusicPlaylistID,
            into: bucket.musicPlaylistID
        )

        let currentTrackID = currentPlaylistItem?.trackID
            ?? activeQueueCurrentLocalTrackID.flatMap(UUID.init(uuidString:))
        currentPlaylistID = bucket.musicPlaylistID
        currentPlaylistItem = currentTrackID.flatMap { itemsByTrackID[$0] }
        for index in activeQueueEntries.indices {
            guard let trackID = UUID(uuidString: activeQueueEntries[index].localTrackID),
                  let item = itemsByTrackID[trackID] else {
                continue
            }
            activeQueueEntries[index].playlistItemID = item.id
        }
        for index in appendedUncorrelatedEntries.indices {
            guard let trackID = UUID(uuidString: appendedUncorrelatedEntries[index].localTrackID),
                  let item = itemsByTrackID[trackID] else {
                continue
            }
            appendedUncorrelatedEntries[index].playlistItemID = item.id
        }

        lastLocalPlaybackStateIdentity = nil
        if let musicItemID = currentTrack?.id {
            persistLocalPlaybackState(musicItemID: musicItemID, forceFlush: true)
        }
        reconcileStoredOrder(for: bucket, context: context)
        rebuildActivePlaylistSnapshot(context: context)
        bumpPlaybackItemMetadataVersion()
        publishNowPlayingMetadata(isPlaying: isPlaying)
    }

    private func mergePlaybackOrdersAfterDemotion(
        from oldMusicPlaylistID: String,
        into bucketMusicPlaylistID: String
    ) {
        let liveQueueTrackIDs = activeQueueEntries.map(\.localTrackID)

        for scope in PlaylistPlaybackScope.allCases {
            let oldID = scope.playbackOrderPlaylistID(for: oldMusicPlaylistID)
            let bucketID = scope.playbackOrderPlaylistID(for: bucketMusicPlaylistID)
            let sourceOrder = PlaybackOrderStore.state(
                playerID: playerID,
                musicPlaylistID: oldID
            ).orderedTrackIDs
            let bucketOrder = PlaybackOrderStore.state(
                playerID: playerID,
                musicPlaylistID: bucketID
            ).orderedTrackIDs
            let orderGroups = scope == currentPlaylistScope
                ? [liveQueueTrackIDs, sourceOrder, bucketOrder]
                : [bucketOrder, sourceOrder]
            var seenTrackIDs = Set<String>()
            let mergedOrder = orderGroups
                .flatMap { $0 }
                .filter { seenTrackIDs.insert($0).inserted }

            if !mergedOrder.isEmpty {
                PlaybackOrderStore.save(
                    PlaybackOrderState(
                        playerID: playerID,
                        musicPlaylistID: bucketID,
                        orderedTrackIDs: mergedOrder
                    ),
                    flushImmediately: true
                )
            }
            PlaybackOrderStore.clear(
                playerID: playerID,
                musicPlaylistID: oldID,
                flushImmediately: true
            )
        }
    }

    func appendLiveQueueEntries(
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
            let generation = appendCorrelationGeneration
            try await player.appendToQueue(entries.map(\.musicTrack))
            guard generation == appendCorrelationGeneration,
                  currentPlaylistID == playlistID,
                  playerStillHoldsOverplayQueue() else {
                return
            }
            // The player creates these entries, so they have to be correlated
            // back rather than assumed: it can report them under the other
            // Apple Music ID domain, or before their items hydrate. Anything
            // unmatched is retried, never dropped — reaching an uncorrelated
            // entry reads as divergence and tears playback down.
            appendedUncorrelatedEntries.append(
                contentsOf: entries.map(PendingQueueCorrelation.init(entry:))
            )
            correlateAppendedEntries()
        } catch {
            statusMessage = "Added tracks locally, but updating the live queue failed: \(error.localizedDescription)"
        }
    }

    private func rebuildActivePlaylistSnapshot(context: ModelContext) {
        guard let currentPlaylistID,
              let playlist = try? currentPlaylist(in: context) else {
            activePlaylistSnapshot = nil
            activePlaylistSnapshotNeedsRebuild = false
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
            activePlaylistSnapshotNeedsRebuild = false
        } catch {
            statusMessage = "Playback is active, but refreshing the visible playlist failed: \(error.localizedDescription)"
        }
    }

    private func updateActivePlaylistSnapshotCurrentRow() {
        guard let activePlaylistSnapshot,
              activePlaylistSnapshot.musicPlaylistID == currentPlaylistID else {
            return
        }

        let updatedSnapshot = activePlaylistSnapshot.updatingCurrentRow(
            currentPlaylistItemID: currentPlaylistItem?.id,
            currentLocalTrackID: nowPlayingDisplayLocalTrackID,
            currentMusicItemID: nowPlayingDisplayTrack?.id ?? currentTrack?.id
        )
        guard updatedSnapshot != activePlaylistSnapshot else { return }
        self.activePlaylistSnapshot = updatedSnapshot
    }
}
