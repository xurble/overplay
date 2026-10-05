import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

/// A failure every surface shows the same way (`PLAY-014`).
struct PlaybackFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case command
        case stalled
    }

    var kind: Kind
    var message: String
    var since: Date
}

/// The single owner of playback (`PLAY-010`–`PLAY-017`).
///
/// Overplay records what it asked MusicKit to play (the intent) and then
/// believes the player about what is audible. Every command is one MusicKit
/// call; all state changes arrive through one observation path, whichever
/// surface caused them. Counting, curation and sync read this state; none of
/// them can gate or rewrite playback. See the Playback Engine section and the
/// History of abandoned approaches in `OVERPLAY_DESIGN_SPEC.md`.
@MainActor
@Observable
final class PlaybackController {
    /// One listening session: an entry the player made current, attributed to
    /// an intent member when possible.
    private struct ObservedSession {
        var entryID: String
        var play: TrackPlaySession
        /// Carried onto a new entry ID before its item hydrated; confirmed or
        /// split when it does.
        var awaitsHydrationCheck = false
        var carriedAt: Date?
        /// The member this session was carried for. Kept after the
        /// unconfirmed limit stops attributing it, so a later hydration as a
        /// different song still splits the session.
        var carriedLocalTrackID: String?
        var isAttributed: Bool { play.localTrackID != nil }
    }

    private enum SessionEnd {
        case changedTrack(backward: Bool)
        case queueEnded
        case replaced
    }

    // MARK: - Observed state

    private(set) var intent: PlaybackIntent?
    /// The player-reported track, enriched with Overplay data when attributed.
    private(set) var currentTrack: CurrentPlaybackTrack?
    /// The intent member the current entry is attributed to, if any.
    private(set) var currentMember: PlaybackIntent.Member?
    var currentPlaylistItem: PlaylistItemRecord? {
        didSet { updateRetentionLease() }
    }
    private(set) var elapsedSeconds: Double = 0
    private(set) var durationSeconds: Double?
    private(set) var isPlaying = false
    /// Whether the player holds a current entry Overplay can command.
    private(set) var hasLiveQueue = false
    private(set) var playbackModes = PlaybackModeState()
    private(set) var playbackFailure: PlaybackFailure?
    var statusMessage: String?
    private(set) var activePlaylistSnapshot: ActivePlaylistSnapshot?
    private(set) var playbackItemMetadataVersion = 0

    // MARK: - Dependencies

    @ObservationIgnored private let player: any PlaybackPlayer
    @ObservationIgnored private let intentStore: PlaybackIntentStore
    @ObservationIgnored private let preparePlaybackTracks: @MainActor ([TrackRecord]) async throws -> Void
    @ObservationIgnored private let refreshUnknownApplePlayCount: (@MainActor (UUID, ModelContext) async -> Int)?
    @ObservationIgnored var isLibraryReady: @MainActor () -> Bool = { true }
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    // MARK: - Internal state

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var attribution: PlaybackAttribution?
    /// Entry ID → attributed local track ID, for this intent only.
    @ObservationIgnored private var attributedEntries: [String: String] = [:]
    @ObservationIgnored private var session: ObservedSession? {
        didSet { updateRetentionLease() }
    }
    @ObservationIgnored private var lastEntryID: String?
    @ObservationIgnored private var lastEntryWasHydrated = false
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var frozenSamples = 0
    @ObservationIgnored private var lastSamplePosition: Double?
    @ObservationIgnored private var lastResumeSaveAt: Date?
    @ObservationIgnored private var cachedSettings: OverplaySettings?
    @ObservationIgnored private var reportedUnattributedEntryID: String?
    /// The entry whose current visit has been checked against the intent's
    /// scope. An entry is checked again each time it becomes current (a track
    /// retired since its last visit is skipped on the next lap), never twice in
    /// one visit, and never after a mid-song carry-over.
    @ObservationIgnored private var scopeCheckedVisitEntryID: String?
    /// Entries skipped for leaving the scope, per intent. An entry is never
    /// skipped twice, so a repeat-all wrap over such entries cannot loop.
    @ObservationIgnored private var skippedEntryIDs: Set<String> = []
    /// The member Overplay asked the latest submission to start at, until the
    /// first entry of that submission is observed.
    @ObservationIgnored private var awaitingFirstEntryOfSubmission: String?
    /// A session continuing across a resubmission of the same track.
    @ObservationIgnored private var pendingCarriedSession: ObservedSession?
    /// Bumped by every start or selection; a slower, older start yields.
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var samplingGeneration = 0
    /// The last recovery rung that ran, so repeated presses escalate.
    @ObservationIgnored private var recoveryEscalation: (rung: Int, at: Date)?
    @ObservationIgnored private var prefetchedArtworkTrackID: String?
    @ObservationIgnored private var appleCountLookupTask: Task<Void, Never>?
    @ObservationIgnored private var appleCountLookupTrackID: UUID?
    @ObservationIgnored private let retentionLease = TrackRetentionPolicy.makePlaybackLease()

    static let samplingInterval: Duration = .seconds(1)
    /// Consecutive frozen samples while playing before a stall is surfaced.
    static let stallSampleThreshold = 10
    static let resumeSaveInterval: TimeInterval = 15

    init(
        player: any PlaybackPlayer = ApplicationMusicPlaybackPlayer(),
        intentStore: PlaybackIntentStore = PlaybackIntentStore(),
        preparePlaybackTracks: @escaping @MainActor ([TrackRecord]) async throws -> Void = { try await DevicePlaybackCache.prepare($0) },
        refreshUnknownApplePlayCount: (@MainActor (UUID, ModelContext) async -> Int)? = nil,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.player = player
        self.intentStore = intentStore
        self.preparePlaybackTracks = preparePlaybackTracks
        self.refreshUnknownApplePlayCount = refreshUnknownApplePlayCount
        self.sleep = sleep
    }

    // MARK: - Derived state

    var currentPlaylistID: String? { intent?.musicPlaylistID }
    var currentPlaylistScope: PlaylistPlaybackScope { intent?.scope ?? .active }
    var nowPlayingDisplayTrack: CurrentPlaybackTrack? { currentTrack }
    var nowPlayingDisplayLocalTrackID: String? { currentMember?.localTrackID }
    var isDeliveryStalled: Bool { playbackFailure != nil }
    var canSkipTracks: Bool { hasLiveQueue }

    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }

    var shuffleEnabled: Bool { playbackModes.shuffle == .songs }
    var repeatMode: MusicPlayer.RepeatMode { playbackModes.repeatMode ?? MusicPlayer.RepeatMode.none }
    var repeatAllEnabled: Bool { playbackModes.repeatMode == .all }
    /// Continuity proof needs an explicit, current off report (`PLAY-004`).
    var hasConfirmedChronologicalPlayback: Bool { player.reportedShuffleMode == .off }

    var playbackModeDiagnosticDescription: String {
        "rawShuffle=\(Self.describe(player.reportedShuffleMode)) effectiveShuffle=\(Self.describe(playbackModes.shuffle)) "
            + "rawRepeat=\(Self.describe(player.reportedRepeatMode)) effectiveRepeat=\(Self.describe(playbackModes.repeatMode))"
    }

    var displayedSkipCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.skipCount ?? currentTrack?.skipCount ?? 0
    }

    var displayedPlaythroughCount: Int {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.playthroughCount ?? currentTrack?.playthroughCount ?? 0
    }

    var displayedApplePlayCount: Int? {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.applePlayCount ?? currentTrack?.applePlayCount
    }

    var displayedIsEvicted: Bool {
        _ = playbackItemMetadataVersion
        return currentPlaylistItem?.evictedAt != nil || currentTrack?.isEvicted == true
    }

    func displayedSkipCount(context: ModelContext) -> Int {
        displayedPlaylistItem(context: context)?.skipCount ?? displayedSkipCount
    }

    func displayedPlaythroughCount(context: ModelContext) -> Int {
        displayedPlaylistItem(context: context)?.playthroughCount ?? displayedPlaythroughCount
    }

    func displayedApplePlayCount(context: ModelContext) -> Int? {
        displayedPlaylistItem(context: context)?.applePlayCount ?? displayedApplePlayCount
    }

    func displayedIsEvicted(context: ModelContext) -> Bool {
        displayedPlaylistItem(context: context).map { $0.evictedAt != nil } ?? displayedIsEvicted
    }

    /// The attributed member's item, read fresh from `context`.
    func displayedPlaylistItem(context: ModelContext) -> PlaylistItemRecord? {
        _ = playbackItemMetadataVersion
        guard let member = currentMember, let trackID = UUID(uuidString: member.localTrackID) else { return nil }
        return try? PlaylistItemRepository.item(trackID: trackID, in: context)
    }

    /// The role of the playlist that owns the attributed item; nil while the
    /// current entry is unattributed, so curation actions are disabled.
    func currentPlaylistRole(context: ModelContext) -> PlaylistRole? {
        if hasLiveQueue, currentMember == nil { return nil }
        if let item = displayedPlaylistItem(context: context),
           let owner = try? PlaylistRepository.playlist(id: item.playlistID, in: context) {
            return owner.role
        }
        return try? currentPlaylist(in: context)?.role
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    func currentQueueContains(playlist: PlaylistRecord, scope: PlaylistPlaybackScope) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentPlaylistScope == scope && hasLiveQueue
    }

    // MARK: - Lifecycle

    /// Restores the persisted intent for display. Needs no database, so it can
    /// run before iCloud restoration (`PLAY-010`).
    func restoreIntent() {
        guard intent == nil, let saved = intentStore.loadIntent() else { return }
        install(saved, persist: false)
        let resume = intentStore.loadResumePoint().flatMap { $0.intentID == saved.id ? $0 : nil }
        let resumeMember = saved.member(localTrackID: resume?.localTrackID)
        let member = resumeMember ?? saved.member(localTrackID: saved.startingLocalTrackID) ?? saved.members.first
        currentMember = member
        // A saved position belongs to the saved track only.
        elapsedSeconds = resumeMember != nil ? resume?.positionSeconds ?? 0 : 0
        isPlaying = false
        applyDisplay(entry: nil, member: member)
    }

    /// Kept for startup: restore the intent and adopt the library context.
    func restoreLocalPlaybackDisplay(context: ModelContext) {
        adopt(context)
        restoreIntent()
        refreshCurrentItem()
        rebuildActivePlaylistSnapshot()
    }

    /// Starts observing the player. Safe to call repeatedly.
    func startMonitoring(context: ModelContext? = nil) {
        if let context { adopt(context) }
        if !isObserving {
            isObserving = true
            player.startObservingChanges { [weak self] _ in
                guard let self, self.isObserving else { return }
                await self.observePlayer()
            }
            // Publishers only report changes; read the player once now so a
            // queue that is already loaded (paused, or playing after a
            // relaunch) is controllable straight away.
            Task { [weak self] in
                guard let self, self.isObserving else { return }
                await self.observePlayer()
            }
        }
        ensureSampling()
    }

    func stopMonitoring() {
        isObserving = false
        player.stopObservingChanges()
        sampleTask?.cancel()
        sampleTask = nil
        appleCountLookupTask?.cancel()
        appleCountLookupTask = nil
    }

    /// One explicit observation pass, for foregrounding and background wakes.
    func reconcilePlayerState(context: ModelContext) async {
        adopt(context)
        startMonitoring()
        await observePlayer()
    }

    func clearLocalStateAfterDatabaseReset() {
        player.pause()
        intentStore.clear()
        PlaybackWaypointStore.clear(flushImmediately: true)
        intent = nil
        attribution = nil
        attributedEntries = [:]
        session = nil
        lastEntryID = nil
        currentMember = nil
        currentTrack = nil
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        playbackFailure = nil
        activePlaylistSnapshot = nil
        cachedSettings = nil
        statusMessage = "Overplay data reset."
        bumpMetadataVersion()
    }

    // MARK: - Observation (`PLAY-011`)

    /// The one path by which player changes reach Overplay, whichever surface
    /// or MusicKit itself caused them.
    func observePlayer() async {
        player.refreshObservationBindings()
        observeModes()
        let status = player.playbackStatus
        isPlaying = status == .playing
        let entry = player.currentEntry
        hasLiveQueue = entry != nil

        if let entry {
            if entry.entryID != lastEntryID {
                await transition(to: entry)
            } else if entry.item != nil, !lastEntryWasHydrated {
                lastEntryWasHydrated = true
                await attributeCurrent(entry)
            }
            let position = player.playbackTime
            elapsedSeconds = position
            updateSessionProgress(position: position)
        } else if lastEntryID != nil {
            await queueBecameEmpty(status: status)
        }
        ensureSampling()
    }

    /// The one-second sample while playing: cheap reads only (`LOAD-001`).
    func samplePlayback(now: Date = .now) async {
        guard player.currentEntryID == lastEntryID else {
            await observePlayer()
            return
        }
        let status = player.playbackStatus
        isPlaying = status == .playing
        guard lastEntryID != nil else { return }
        let position = player.playbackTime
        elapsedSeconds = position
        updateSessionProgress(position: position, now: now)
        detectStall(status: status, position: position)
        saveResumePoint(force: false, now: now)
    }

    private func ensureSampling() {
        let status = player.playbackStatus
        let moving = status == .playing || status == .seekingForward || status == .seekingBackward
        guard moving else {
            sampleTask?.cancel()
            sampleTask = nil
            return
        }
        guard sampleTask == nil else { return }
        samplingGeneration &+= 1
        let generation = samplingGeneration
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.samplingGeneration else { return }
                await self.sleep(Self.samplingInterval)
                guard !Task.isCancelled, generation == self.samplingGeneration else { return }
                await self.samplePlayback()
                let status = self.player.playbackStatus
                if status != .playing && status != .seekingForward && status != .seekingBackward {
                    // Only the current loop may clear the reference.
                    if generation == self.samplingGeneration { self.sampleTask = nil }
                    return
                }
            }
        }
    }

    private func observeModes() {
        var modes = playbackModes
        modes.observe(shuffle: player.reportedShuffleMode, repeatMode: player.reportedRepeatMode)
        guard modes != playbackModes else { return }
        MusicKitActivityLog.shared.record(.playerModeObserved, detail: "shuffle=\(Self.describe(modes.shuffle)) repeat=\(Self.describe(modes.repeatMode))")
        playbackModes = modes
    }

    private func transition(to entry: PlayerEntrySnapshot) async {
        let previousEntryID = lastEntryID
        let position = player.playbackTime
        // The first entry after a submission is the one Overplay asked to
        // start at. Until its item hydrates that is the best description; the
        // hydrated item confirms or overrides it.
        if let start = awaitingFirstEntryOfSubmission {
            awaitingFirstEntryOfSubmission = nil
            if entry.item == nil { attributedEntries[entry.entryID] = start }
        }
        let incoming = member(for: entry)
            ?? (entry.item == nil ? attribution?.member(localTrackID: attributedEntries[entry.entryID]) : nil)

        // A resubmission of the track already playing (recovery, resume)
        // continues its session rather than judging it.
        if let carried = pendingCarriedSession {
            pendingCarriedSession = nil
            if incoming?.localTrackID == carried.play.localTrackID {
                await carryOver(carried, to: entry, confirmed: entry.item != nil)
                return
            }
            // Recovery or resume was interrupted by Overplay, not the user:
            // the carried listen is dropped rather than judged.
            TrackMetadataDiagnostics.log("carried session dropped: resubmission started elsewhere")
        }

        if let outgoing = session {
            // MusicKit can re-issue entry IDs for the song that is playing
            // (for example after a mode change). Same song, continuous
            // position: the same session, not a skip.
            let continuous = position >= 1 && abs(position - outgoing.play.lastObservedPlaybackTime) <= 3
            let sameMember = incoming != nil && incoming?.localTrackID == outgoing.play.localTrackID
            let notYetKnown = entry.item == nil && outgoing.isAttributed
            if continuous, sameMember || notYetKnown {
                await carryOver(outgoing, to: entry, confirmed: sameMember)
                return
            }
            let completedNaturally = PlaybackSessionEvaluationService.inferredNaturalCompletion(session: outgoing.play)
            let backward = !completedNaturally && (previousEntryID.map { isBackward(from: $0, to: entry.entryID) } ?? false)
            finish(outgoing, end: .changedTrack(backward: backward))
        }
        lastEntryID = entry.entryID
        lastEntryWasHydrated = entry.item != nil
        // A new visit: the entry is checked against the scope again.
        scopeCheckedVisitEntryID = nil
        session = ObservedSession(
            entryID: entry.entryID,
            play: PlaybackSessionSupport.makeSession(
                trackID: entry.item?.id ?? entry.entryID,
                elapsedSeconds: position,
                durationSeconds: entry.item?.durationSeconds
            )
        )
        frozenSamples = 0
        lastSamplePosition = nil
        await attributeCurrent(entry)
        saveResumePoint(force: true)
    }

    /// Moves a session onto a new entry ID for the same song. Unconfirmed
    /// carry-overs are checked again when the entry's item hydrates.
    private func carryOver(_ carried: ObservedSession, to entry: PlayerEntrySnapshot, confirmed: Bool) async {
        var session = carried
        session.entryID = entry.entryID
        session.awaitsHydrationCheck = !confirmed
        session.carriedAt = confirmed ? nil : .now
        session.carriedLocalTrackID = carried.play.localTrackID
        if let localTrackID = carried.play.localTrackID { attributedEntries[entry.entryID] = localTrackID }
        scopeCheckedVisitEntryID = entry.entryID
        self.session = session
        lastEntryID = entry.entryID
        lastEntryWasHydrated = entry.item != nil
        MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "sessionCarriedOver confirmed=\(confirmed)")
        await attributeCurrent(entry)
        saveResumePoint(force: true)
    }

    /// Attributes the current entry and publishes the display. Never clears
    /// the intent or the playlist context (`PLAY-012`).
    private func attributeCurrent(_ entry: PlayerEntrySnapshot) async {
        let member = member(for: entry)
        currentMember = member ?? (entry.item == nil ? attribution?.member(localTrackID: attributedEntries[entry.entryID]) : nil)
        if var current = session, current.entryID == entry.entryID {
            if let item = entry.item {
                if current.awaitsHydrationCheck, member?.localTrackID != current.carriedLocalTrackID {
                    // The carried session belonged to another song after all:
                    // end it and start this song's own session and visit.
                    finish(current, end: .changedTrack(backward: false))
                    current = ObservedSession(entryID: entry.entryID, play: PlaybackSessionSupport.makeSession(
                        trackID: item.id, elapsedSeconds: player.playbackTime, durationSeconds: item.durationSeconds
                    ))
                    scopeCheckedVisitEntryID = nil
                }
                current.awaitsHydrationCheck = false
                current.carriedLocalTrackID = nil
                // A hydrated item's attribution is authoritative, including
                // "none", and so is its duration.
                current.play.localTrackID = member?.localTrackID
                current.play.trackID = item.id
                current.play.durationSeconds = item.durationSeconds ?? member?.durationSeconds ?? current.play.durationSeconds
            } else {
                if current.play.localTrackID == nil { current.play.localTrackID = currentMember?.localTrackID }
                if current.play.durationSeconds == nil { current.play.durationSeconds = currentMember?.durationSeconds }
            }
            session = current
        }
        if member == nil, entry.item != nil {
            // A tentative or carried guess the item does not confirm is gone.
            attributedEntries[entry.entryID] = nil
        }
        if member == nil, entry.item != nil, reportedUnattributedEntryID != entry.entryID {
            reportedUnattributedEntryID = entry.entryID
            MusicKitActivityLog.shared.record(.queueCorrelationRejected,
                detail: "unattributed entry=\(entry.entryID) title=\(entry.item?.title ?? "nil") intent=\(intent?.id.uuidString ?? "nil")")
        }
        refreshCurrentItem()
        applyDisplay(entry: entry, member: currentMember)
        updateActivePlaylistSnapshotCurrentRow()
        prioritizeUnknownApplePlayCount()
        await skipIfMemberLeftScope(entry: entry)
    }

    private func member(for entry: PlayerEntrySnapshot) -> PlaybackIntent.Member? {
        guard let attribution, let item = entry.item else { return nil }
        let member = attribution.member(for: item, cachedLocalTrackID: attributedEntries[entry.entryID])
        if let member { attributedEntries[entry.entryID] = member.localTrackID }
        return member
    }

    /// Previous from any surface is not a skip. The player's queue order says
    /// whether the new entry precedes the old one, shuffled or not. A repeat-all
    /// wrap from the last entry to the first is forward.
    private func isBackward(from oldEntryID: String, to newEntryID: String) -> Bool {
        let order = player.queueEntries.map(\.entryID)
        guard let oldIndex = order.firstIndex(of: oldEntryID), let newIndex = order.firstIndex(of: newEntryID) else {
            return false
        }
        let repeatsAll = playbackModes.repeatMode == .all
        if repeatsAll, order.count > 1, oldIndex == order.count - 1, newIndex == 0 { return false }
        if repeatsAll, order.count > 2, oldIndex == 0, newIndex == order.count - 1 { return true }
        return newIndex < oldIndex
    }

    private func queueBecameEmpty(status: MusicPlayer.PlaybackStatus) async {
        let outgoing = session
        let completed = outgoing.map { PlaybackSessionEvaluationService.inferredNaturalCompletion(session: $0.play) } ?? false
        // A stale last observation means the end happened while Overplay was
        // suspended: most likely the queue played out. Unknown, not a failure.
        let stale = outgoing.map {
            Date.now.timeIntervalSince($0.play.lastObservedAt) > PlaybackSessionEvaluationService.observationStalenessThresholdSeconds
        } ?? true
        let stoppedMidTrack = !completed && !stale
        MusicKitActivityLog.shared.record(.queueEndObserved,
            detail: completed ? "played out" : stale ? "ended while suspended" : "stopped mid-track")
        if let outgoing, completed {
            finish(outgoing, end: .queueEnded)
        }
        session = nil
        lastEntryID = nil
        lastEntryWasHydrated = false
        guard let intent else { return }
        if stoppedMidTrack {
            // Keep the member and position, so Play resumes where it stopped.
            fail(kind: .command, message: Self.playbackStoppedMessage)
            saveResumePoint(force: true)
            return
        }
        // The queue ended. The intent stays; Play starts it from the beginning.
        currentMember = intent.members.first
        elapsedSeconds = 0
        applyDisplay(entry: nil, member: currentMember)
        refreshCurrentItem()
        intentStore.save(PlaybackResumePoint(intentID: intent.id, localTrackID: currentMember?.localTrackID,
                                             positionSeconds: 0, wasPlaying: false, updatedAt: .now))
    }

    // MARK: - Sessions and counting (`COUNT-001`)

    static let unconfirmedCarryOverLimit: TimeInterval = 10

    private func updateSessionProgress(position: Double, now: Date = .now) {
        guard var current = session, current.entryID == lastEntryID else { return }
        if current.awaitsHydrationCheck, let carriedAt = current.carriedAt,
           now.timeIntervalSince(carriedAt) > Self.unconfirmedCarryOverLimit {
            // Never confirmed: stop attributing listening to a guess, but keep
            // checking, so a late hydration as another song still splits.
            current.carriedAt = nil
            current.play.localTrackID = nil
        }
        current.play = PlaybackSessionEvaluationService.updateObservedProgress(
            current.play, elapsedSeconds: position, durationSeconds: current.play.durationSeconds ?? durationSeconds, observedAt: now
        )
        session = current
        evaluatePlaythroughIfNeeded()
    }

    private func evaluatePlaythroughIfNeeded() {
        guard let current = session, current.isAttributed, !current.play.hasEvaluated,
              let progress = current.play.progressPercentage,
              let context = countingContext(), let settings = settings(in: context),
              progress >= settings.playthroughThresholdPercentage else { return }
        if alreadyCreditedThisPlay(current, in: context) {
            session?.play.hasEvaluated = true
            return
        }
        do {
            let outcome = try PlaybackSessionEvaluationService.evaluatePlaythroughIfNeeded(
                session: current.play,
                currentPlaylistItem: item(for: current, in: context),
                playlist: try currentPlaylist(in: context),
                settings: settings,
                context: context,
                fallbackLocalTrackID: current.play.localTrackID
            )
            if let outcome {
                session?.play = outcome.session
                applyOutcome(outcome)
            }
        } catch {
            TrackMetadataDiagnostics.log("playthrough evaluation failed: \(error.localizedDescription)")
        }
    }

    /// Evaluates a session that has ended, exactly once. A failure here is a
    /// lost count, never a playback change.
    private func finish(_ ended: ObservedSession, end: SessionEnd) {
        if session?.entryID == ended.entryID { session = nil }
        guard !ended.play.hasEvaluated else { return }
        guard ended.isAttributed else {
            TrackMetadataDiagnostics.log("listening not counted: entry \(ended.entryID) was never attributed")
            return
        }
        if case .changedTrack(backward: true) = end { return }
        guard let context = countingContext(), let settings = settings(in: context) else {
            TrackMetadataDiagnostics.log("listening not counted: library unavailable")
            return
        }
        guard !alreadyCreditedThisPlay(ended, in: context) else { return }
        do {
            let outcome = try PlaybackSessionEvaluationService.evaluateActiveSession(
                activeSession: ended.play,
                currentTrackID: ended.play.trackID,
                elapsedSeconds: ended.play.lastObservedPlaybackTime,
                durationSeconds: ended.play.durationSeconds,
                currentPlaylistItem: item(for: ended, in: context),
                playlist: try currentPlaylist(in: context),
                settings: settings,
                naturalCompletion: {
                    if case .queueEnded = end { return true }
                    return false
                }(),
                context: context,
                fallbackLocalTrackID: ended.play.localTrackID
            )
            if let outcome { applyOutcome(outcome) }
        } catch {
            TrackMetadataDiagnostics.log("session evaluation failed: \(error.localizedDescription)")
        }
    }

    private func applyOutcome(_ outcome: PlaybackSessionEvaluationService.EvaluationOutcome) {
        guard let item = outcome.item else { return }
        if item.trackID.uuidString == currentMember?.localTrackID {
            currentPlaylistItem = item
            applyDisplay(entry: player.currentEntry, member: currentMember)
        }
        patchActivePlaylistSnapshotRow(for: item)
        cleanUpRetentionIfNeeded(item)
        bumpMetadataVersion()
    }

    /// Suspended-playback reconciliation may already have credited this very
    /// play (point proof) before the controller observed it. A playthrough
    /// recorded after the estimated start of this play means it is counted.
    private func alreadyCreditedThisPlay(_ session: ObservedSession, in context: ModelContext) -> Bool {
        guard let lastPlayedAt = item(for: session, in: context)?.lastPlayedAt else { return false }
        let estimatedStart = session.play.lastObservedAt.addingTimeInterval(
            -(session.play.lastObservedPlaybackTime + PlaybackReconciliationPolicy.baseToleranceSeconds)
        )
        return lastPlayedAt >= estimatedStart
    }

    private func item(for session: ObservedSession, in context: ModelContext) -> PlaylistItemRecord? {
        guard let localTrackID = session.play.localTrackID, let trackID = UUID(uuidString: localTrackID) else { return nil }
        return try? PlaylistItemRepository.item(trackID: trackID, in: context)
    }

    private func markSessionEvaluatedWithoutSkip() {
        session?.play.hasEvaluated = true
    }

    private func cleanUpRetentionIfNeeded(_ item: PlaylistItemRecord) {
        guard item.pendingRetentionCleanup, session?.play.hasEvaluated != false,
              let context = countingContext() else { return }
        item.pendingRetentionCleanup = false
        do {
            if try TrackRetentionPolicy.deleteIfUnowned(item, in: context), currentPlaylistItem?.id == item.id {
                currentPlaylistItem = nil
            }
            try context.save()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // MARK: - Transport (`PLAY-013`)

    func play(context: ModelContext) async {
        adopt(context)
        if playbackFailure != nil {
            await recover()
        } else if player.currentEntryID != nil {
            do {
                try await player.play()
                clearFailure()
            } catch {
                fail(error)
            }
        } else if let intent {
            await resubmit(intent, from: currentMember, position: elapsedSeconds)
        } else {
            statusMessage = "Choose a playlist first."
        }
        await observePlayer()
    }

    func pause() {
        player.pause()
        isPlaying = false
        saveResumePoint(force: true)
        ensureSampling()
    }

    /// While a failure is shown, the primary action is Retry: a stalled
    /// player still reports `.playing`, so pausing would be the wrong answer.
    /// Pause stays available from every system surface.
    func togglePlayPause(context: ModelContext) async {
        if playbackFailure == nil, player.playbackStatus == .playing {
            pause()
        } else {
            await play(context: context)
        }
    }

    func performPrimaryPlaybackAction(settings: OverplaySettings, context: ModelContext) async {
        if playbackFailure == nil, isPlaying || player.playbackStatus == .playing {
            pause()
        } else {
            await playCurrentOrDefault(settings: settings, context: context)
        }
    }

    /// Play resumes whatever Overplay knows about; only with nothing at all
    /// does it start the default playlist.
    func playCurrentOrDefault(settings: OverplaySettings, context: ModelContext) async {
        adopt(context)
        if hasLiveQueue || player.currentEntryID != nil || intent != nil {
            await play(context: context)
            return
        }
        guard let playlist = try? PlaybackTrackResolver.defaultPlaybackPlaylist(settings: settings, in: context) else {
            statusMessage = "Choose a playlist first."
            return
        }
        await playPlaylist(playlist, settings: settings, context: context)
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        adopt(context)
        do {
            try await player.skipToNextEntry()
        } catch {
            TrackMetadataDiagnostics.log("skip to next failed: \(error.localizedDescription)")
        }
        await observePlayer()
    }

    func previous(context: ModelContext) async {
        adopt(context)
        do {
            try await player.skipToPreviousEntry()
        } catch {
            TrackMetadataDiagnostics.log("skip to previous failed: \(error.localizedDescription)")
        }
        await observePlayer()
    }

    func toggleShuffle(context: ModelContext) async {
        await setShuffleEnabled(!shuffleEnabled, context: context)
    }

    /// MusicKit owns shuffle (`PLAY-004`): write it, then read back.
    func setShuffleEnabled(_ isEnabled: Bool, context: ModelContext) async {
        adopt(context)
        player.setShuffleMode(isEnabled ? .songs : .off)
        observeModes()
    }

    func toggleRepeatAll(context: ModelContext) async {
        await setRepeatMode(repeatAllEnabled ? MusicPlayer.RepeatMode.none : .all, context: context)
    }

    func setRepeatMode(_ mode: MusicPlayer.RepeatMode, context: ModelContext) async {
        adopt(context)
        player.setRepeatMode(mode)
        observeModes()
    }

    // MARK: - Starting and selecting (`PLAY-005`, `SURFACE-003`)

    func playPlaylist(settings: OverplaySettings, context: ModelContext) async {
        guard let playlistID = settings.selectedPlaylistID,
              let playlist = try? PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) else {
            statusMessage = "Choose a playlist first."
            return
        }
        await playPlaylist(playlist, settings: settings, context: context)
    }

    /// Shuffle and Play.
    func playPlaylist(
        _ playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        adopt(context)
        await startPlayback(playlist, scope: scope, startingTrackID: nil, shuffle: true, context: context)
    }

    /// The single track-selection action for every surface.
    func playPlaylist(
        _ playlist: PlaylistRecord,
        startingAt track: TrackRecord,
        scope: PlaylistPlaybackScope = .active,
        settings: OverplaySettings,
        context: ModelContext
    ) async {
        adopt(context)
        let localTrackID = track.id.uuidString
        guard let intent, intent.musicPlaylistID == playlist.musicPlaylistID, intent.scope == scope,
              let member = intent.member(localTrackID: localTrackID) else {
            MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "newIntent")
            await startPlayback(playlist, scope: scope, startingTrackID: localTrackID, shuffle: false, context: context)
            return
        }

        if currentMember?.localTrackID == localTrackID {
            // The current track resumes, never restarts, live queue or not.
            MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "resumeCurrent")
            if player.currentEntryID == nil || player.playbackStatus != .playing { await play(context: context) }
            return
        }

        if let entryID = liveEntryID(for: member) {
            MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "inIntentJump")
            startGeneration &+= 1
            do {
                try player.selectEntry(withID: entryID)
                try await player.play()
                clearFailure()
                await observePlayer()
                return
            } catch {
                guard (error as? PlaybackQueueEntryError) == .entryNotInQueue else {
                    fail(error)
                    await observePlayer()
                    return
                }
            }
        }
        MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "resubmitFromMember")
        await resubmit(intent, from: member, position: 0)
        await observePlayer()
    }

    private func liveEntryID(for member: PlaybackIntent.Member) -> String? {
        guard let attribution else { return nil }
        let entries = player.queueEntries
        if let cached = entries.first(where: { entry in
            guard attributedEntries[entry.entryID] == member.localTrackID else { return false }
            // A cached match must still be what the entry's item says it is.
            guard let item = entry.item else { return true }
            return attribution.member(for: item, cachedLocalTrackID: member.localTrackID)?.localTrackID == member.localTrackID
        }) {
            return cached.entryID
        }
        for entry in entries {
            guard let item = entry.item,
                  let match = attribution.member(for: item, cachedLocalTrackID: attributedEntries[entry.entryID]) else { continue }
            attributedEntries[entry.entryID] = match.localTrackID
            if match.localTrackID == member.localTrackID { return entry.entryID }
        }
        return nil
    }

    private func startPlayback(
        _ playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope,
        startingTrackID: String?,
        shuffle: Bool,
        context: ModelContext
    ) async {
        let inputs: PlaybackQueueOrchestrator.PlaylistInputs
        do {
            inputs = try PlaybackQueueOrchestrator.playlistInputs(for: playlist.musicPlaylistID, in: context)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let items = PlaylistDisplayOrder.orderedItems(inputs.items.filter { scope.includes($0) }, scope: scope)
        let records = items.compactMap { inputs.tracksByID[$0.trackID] }
        guard !records.isEmpty else {
            statusMessage = "No \(scope.title.lowercased()) tracks in \(playlist.name)."
            return
        }
        startGeneration &+= 1
        let generation = startGeneration
        let resolved = await resolvePlayableTracks(records)
        // A newer start or selection happened while this one prepared.
        guard generation == startGeneration else { return }
        let itemsByTrackID = items.firstValueDictionary(keyedBy: \.trackID)
        let playable = records.compactMap { record -> (PlaybackIntent.Member, Track)? in
            guard let track = resolved[record.id] else { return nil }
            return (Self.member(for: record, item: itemsByTrackID[record.id], track: track), track)
        }
        guard !playable.isEmpty else {
            statusMessage = "None of the tracks in \(playlist.name) could be prepared for playback."
            return
        }
        let startIndex: Int
        if shuffle {
            startIndex = Int.random(in: playable.indices)
        } else if let startingTrackID {
            guard let index = playable.firstIndex(where: { $0.0.localTrackID == startingTrackID }) else {
                statusMessage = "That track is unavailable in Apple Music right now."
                return
            }
            startIndex = index
        } else {
            startIndex = 0
        }
        let omitted = records.count - playable.count
        let intent = PlaybackIntent(
            id: UUID(),
            createdAt: .now,
            musicPlaylistID: playlist.musicPlaylistID,
            scope: scope,
            members: playable.map(\.0),
            startingLocalTrackID: playable[startIndex].0.localTrackID
        )
        await submit(intent, tracks: playable.map(\.1), startIndex: startIndex, position: 0, shuffle: shuffle,
                     generation: generation)
        if omitted > 0, playbackFailure == nil, generation == startGeneration {
            statusMessage = omitted == 1
                ? "1 track couldn't be prepared and was left out."
                : "\(omitted) tracks couldn't be prepared and were left out."
        }
        await ArtworkCacheService.shared.touchPlaylistUsage(playlist.musicPlaylistID)
        await observePlayer()
    }

    /// Resubmits an existing intent from a member, for resume, recovery and
    /// selection when the entry cannot be found in the live queue.
    private func resubmit(_ intent: PlaybackIntent, from member: PlaybackIntent.Member?, position: Double) async {
        startGeneration &+= 1
        let generation = startGeneration
        let records = intent.members.compactMap { member -> TrackRecord? in
            guard let id = UUID(uuidString: member.localTrackID), let context = countingContext() else { return nil }
            return try? TrackRecordRepository.track(id: id, in: context)
        }
        let resolved = await resolvePlayableTracks(records, fallbackLocalTrackIDs: intent.members.map(\.localTrackID))
        guard generation == startGeneration else { return }
        let playable = intent.members.compactMap { member -> (PlaybackIntent.Member, Track)? in
            guard let id = UUID(uuidString: member.localTrackID), let track = resolved[id] else { return nil }
            return (member, track)
        }
        guard !playable.isEmpty else {
            fail(kind: .command, message: "Overplay couldn't prepare this playlist for Apple Music. Check your connection and press Play again.")
            return
        }
        let startIndex = member.flatMap { member in playable.firstIndex { $0.0.localTrackID == member.localTrackID } } ?? 0
        var resubmitted = intent
        resubmitted.id = UUID()
        resubmitted.createdAt = .now
        resubmitted.members = playable.map(\.0)
        resubmitted.startingLocalTrackID = playable[startIndex].0.localTrackID
        let startPosition = playable[startIndex].0.localTrackID == member?.localTrackID ? position : 0
        // Resuming the track that is playing continues its listening session.
        let continuesSession = startPosition > 0 && session?.play.localTrackID == playable[startIndex].0.localTrackID
        await submit(resubmitted, tracks: playable.map(\.1), startIndex: startIndex, position: startPosition, shuffle: false,
                     generation: generation, continuesSession: continuesSession)
    }

    /// Records the intent, then hands MusicKit the queue in single calls.
    private func submit(
        _ intent: PlaybackIntent,
        tracks: [Track],
        startIndex: Int,
        position: Double,
        shuffle: Bool,
        generation: Int,
        continuesSession: Bool = false
    ) async {
        let carried = continuesSession ? session : nil
        if carried == nil, let outgoing = session { finish(outgoing, end: .replaced) }
        install(intent, persist: true)
        pendingCarriedSession = carried
        awaitingFirstEntryOfSubmission = intent.startingLocalTrackID
        currentMember = intent.members.indices.contains(startIndex) ? intent.members[startIndex] : intent.members.first
        elapsedSeconds = position
        applyDisplay(entry: nil, member: currentMember)
        refreshCurrentItem()
        rebuildActivePlaylistSnapshot()

        player.pause()
        player.submitQueue(tracks, startingAt: startIndex)
        do {
            try await player.play()
            // A newer start replaced this queue while play was in flight.
            guard generation == startGeneration else { return }
            if let duration = currentMember?.durationSeconds, position > 5, position < duration - 5 {
                player.playbackTime = position
            }
            if shuffle {
                // MusicKit ignores shuffle written before the queue loads.
                player.setShuffleMode(.off)
                player.setShuffleMode(.songs)
            }
            clearFailure()
            statusMessage = nil
        } catch {
            guard generation == startGeneration else { return }
            fail(error)
        }
        saveResumePoint(force: true)
    }

    private func install(_ intent: PlaybackIntent, persist: Bool) {
        let playlistChanged = self.intent?.musicPlaylistID != intent.musicPlaylistID
        self.intent = intent
        attribution = PlaybackAttribution(intent: intent)
        attributedEntries = [:]
        lastEntryID = nil
        lastEntryWasHydrated = false
        session = nil
        pendingCarriedSession = nil
        awaitingFirstEntryOfSubmission = nil
        scopeCheckedVisitEntryID = nil
        skippedEntryIDs = []
        if persist {
            do {
                try intentStore.save(intent)
            } catch {
                TrackMetadataDiagnostics.log("playback intent save failed: \(error.localizedDescription)")
            }
        }
        if playlistChanged {
            let playlistID = intent.musicPlaylistID
            Task { await ArtworkCacheService.shared.protectPlaylist(playlistID) }
        }
    }

    /// Native tracks from the device cache, preparing any that are missing.
    /// Unresolvable tracks are simply absent from the result (`PLAY-017`).
    private func resolvePlayableTracks(_ records: [TrackRecord], fallbackLocalTrackIDs: [String] = []) async -> [UUID: Track] {
        if !records.isEmpty {
            do {
                try await preparePlaybackTracks(records)
            } catch {
                TrackMetadataDiagnostics.log("playback preparation incomplete: \(error.localizedDescription)")
            }
        }
        var resolved: [UUID: Track] = [:]
        let ids = Set(records.map(\.id) + fallbackLocalTrackIDs.compactMap(UUID.init(uuidString:)))
        for id in ids {
            if let data = DevicePlaybackCache.shared.data(for: id),
               let track = try? JSONDecoder().decode(Track.self, from: data),
               Self.isQueueable(track) {
                resolved[id] = track
            }
        }
        return resolved
    }

    /// Music videos never enter a playback queue.
    static func isQueueable(_ track: Track) -> Bool {
        VideoTrackPolicy.isSong(track)
    }

    static func member(for record: TrackRecord, item: PlaylistItemRecord?, track: Track) -> PlaybackIntent.Member {
        let identity = MusicTrackIdentity.ids(for: track)
        var ids = PlaybackQueueBuilder.musicItemIDs(for: record)
        for id in [track.id.rawValue, identity.catalogID, identity.libraryID].compactMap({ $0 }) where !ids.contains(id) {
            ids.append(id)
        }
        return PlaybackIntent.Member(
            localTrackID: record.id.uuidString,
            playlistItemID: item?.id,
            musicItemIDs: ids,
            title: record.title,
            artistName: record.artistName,
            albumTitle: record.albumTitle,
            artworkURLTemplate: record.artworkURLTemplate,
            durationSeconds: record.durationSeconds ?? track.duration
        )
    }

    // MARK: - Failure and recovery (`PLAY-014`)

    static let recoveryEscalationWindow: TimeInterval = 120

    /// Runs only on a user Play press, at most once per press. A stalled
    /// player already reports `.playing`, so a bare `play()` proves nothing:
    /// stalls start at rung 2. A press soon after an earlier recovery starts
    /// one rung higher than the last, so repeated failures reach rung 3.
    private func recover(now: Date = .now) async {
        var firstRung = playbackFailure?.kind == .stalled ? 2 : 1
        if let escalation = recoveryEscalation, now.timeIntervalSince(escalation.at) < Self.recoveryEscalationWindow {
            firstRung = max(firstRung, escalation.rung + 1)
        }
        if player.currentEntryID == nil { firstRung = 3 }
        firstRung = min(firstRung, 3)
        MusicKitActivityLog.shared.record(.playbackRecoveryAttempt, magnitude: Double(firstRung), detail: "user play")
        resetStallEvidence()

        if firstRung <= 1, (try? await player.play()) != nil {
            recovered(rung: 1, at: now)
            return
        }
        if firstRung <= 2, (try? await player.prepareToPlay()) != nil, (try? await player.play()) != nil {
            recovered(rung: 2, at: now)
            return
        }
        guard let intent else {
            fail(kind: .command, message: Self.notRespondingMessage)
            return
        }
        // The failure stays until the resubmission succeeds, so background
        // gates stay closed and the control stays Retry while it prepares.
        // Escalation is recorded first: a press during preparation supersedes
        // this one at rung 3, and its newer generation drops this resubmit.
        recoveryEscalation = (3, now)
        let messageBefore = playbackFailure?.message
        let generation = startGeneration &+ 1
        await resubmit(intent, from: currentMember ?? intent.members.first, position: elapsedSeconds)
        guard startGeneration == generation else { return }
        // Keep a more specific message from the resubmission itself.
        if let failure = playbackFailure, failure.message == messageBefore {
            fail(kind: .command, message: Self.notRespondingMessage)
        }
    }

    private func recovered(rung: Int, at date: Date) {
        recoveryEscalation = (rung, date)
        resetStallEvidence()
        clearFailure()
    }

    /// A recovery gets a fresh stall window to buffer in.
    private func resetStallEvidence() {
        frozenSamples = 0
        lastSamplePosition = nil
    }

    private func detectStall(status: MusicPlayer.PlaybackStatus, position: Double) {
        defer { lastSamplePosition = position }
        guard status == .playing, let last = lastSamplePosition else {
            frozenSamples = 0
            return
        }
        if position > last + 0.1 {
            frozenSamples = 0
            // Witnessed progress clears any failure, including a command
            // error after which MusicKit started playing anyway.
            clearFailure()
            return
        }
        frozenSamples += 1
        if frozenSamples >= Self.stallSampleThreshold, playbackFailure == nil {
            fail(kind: .stalled, message: Self.deliveryStallMessage)
        }
    }

    private func fail(_ error: Error) {
        fail(kind: .command, message: Self.failureMessage(for: error))
    }

    private func fail(kind: PlaybackFailure.Kind, message: String) {
        if playbackFailure == nil {
            MusicKitActivityLog.shared.record(.deliveryStallDetected, detail: message)
        }
        playbackFailure = PlaybackFailure(kind: kind, message: message, since: playbackFailure?.since ?? .now)
        statusMessage = message
    }

    private func clearFailure() {
        guard let failure = playbackFailure else { return }
        playbackFailure = nil
        if statusMessage == failure.message { statusMessage = nil }
    }

    static let deliveryStallMessage =
        "Playback stalled — check your network connection, then press Play to retry."
    static let playbackStoppedMessage =
        "Playback stopped before the track finished. Press Play to resume."
    static let notRespondingMessage =
        "Apple Music isn't responding. Wait a moment and press Play again."

    static func failureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "MPMusicPlayerControllerErrorDomain" {
            return "Apple Music playback couldn't start (\(nsError.code)). Press Play to try again."
        }
        return error.localizedDescription
    }

    // MARK: - Curation of the current track

    func promoteCurrent(settings: OverplaySettings, context: ModelContext) async {
        adopt(context)
        guard let item = displayedPlaylistItem(context: context),
              let playlist = try? PlaylistRepository.playlist(id: item.playlistID, in: context) else {
            statusMessage = "Choose a linked triage track to promote."
            return
        }
        let entryID = player.currentEntryID
        do {
            try await promoteTrack(item, playlist: playlist, context: context)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        statusMessage = "Moved to the One True Playlist."
        guard player.currentEntryID == entryID else { return }
        markSessionEvaluatedWithoutSkip()
        await next(settings: settings, context: context)
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
        adopt(context)
        guard let item = displayedPlaylistItem(context: context),
              let playlist = try? PlaylistRepository.playlist(id: item.playlistID, in: context) else {
            statusMessage = "Choose a linked playlist track to retire."
            return
        }
        evaluatePlaythroughIfNeeded()
        markSessionEvaluatedWithoutSkip()
        do {
            try retireTrack(item, playlist: playlist, message: "Retired manually", context: context)
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        if player.currentEntryID != nil {
            await next(settings: settings, context: context)
        }
    }

    @discardableResult
    func restoreCurrent(context: ModelContext) -> Bool {
        adopt(context)
        guard let item = displayedPlaylistItem(context: context) else {
            statusMessage = "Choose a retired track to restore."
            return false
        }
        do {
            try restoreTrack(item, playlist: try? PlaylistRepository.playlist(id: item.playlistID, in: context), context: context)
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        statusMessage = "Moved to Triage."
        return true
    }

    @discardableResult
    func resetCurrentSkipCount(context: ModelContext, message: String = "Skip count reset by user") -> Bool {
        guard let item = displayedPlaylistItem(context: context),
              let playlist = try? PlaylistRepository.playlist(id: item.playlistID, in: context) else {
            statusMessage = "Choose a linked playlist track to reset."
            return false
        }
        do {
            let protecting = session?.play.hasEvaluated == false ? item.id : nil
            _ = try TrackActionService.resetSkipCount(item, playlist: playlist, message: message,
                                                      protectingItemID: protecting, in: context)
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
        reconcileTrackMembership(context: context)
        return true
    }

    // MARK: - Shared mutations (never touch the live queue, `PLAY-015`)

    func retireTrack(_ item: PlaylistItemRecord, playlist: PlaylistRecord, message: String, context: ModelContext) throws {
        settleSessionBeforeMoving(item)
        let itemID = item.id
        _ = try TrackActionService.evictTrack(item, playlist: playlist, message: message, in: context)
        reconcileTrackMembership(context: context)
        guard playlist.role == .oneTruePlaylist else { return }
        let playlistID = playlist.id
        let container = context.container
        Task {
            let remoteContext = ModelContext(container)
            guard let liveItem = try? PlaylistItemRepository.item(id: itemID, in: remoteContext),
                  let livePlaylist = try? PlaylistRepository.playlist(id: playlistID, in: remoteContext) else { return }
            await self.removeEvictedItemFromPlaylist(liveItem, playlist: livePlaylist, context: remoteContext)
        }
    }

    func restoreTrack(_ item: PlaylistItemRecord, playlist: PlaylistRecord?, context: ModelContext) throws {
        settleSessionBeforeMoving(item)
        try TrackActionService.restoreTrack(item, playlist: playlist, in: context)
        reconcileTrackMembership(context: context)
    }

    @discardableResult
    func promoteTrack(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async throws -> PlaylistItemRecord {
        let promoted = try await PlaylistMutationService().promote(
            item: item, beforeMove: { self.settleSessionBeforeMoving(item) }, in: context
        )
        reconcileTrackMembership(context: context)
        return promoted
    }

    func removeTriageSource(_ playlist: PlaylistRecord, context: ModelContext) throws {
        try PlaylistRepository.removeTriageSource(playlist, in: context)
        reconcileTrackMembership(context: context)
    }

    func resetAllLocalStats(context: ModelContext) throws {
        try PlaylistItemRepository.resetAllStats(in: context)
        reconcileTrackMembership(context: context)
    }

    func mergeDuplicateTracks(
        _ selected: [DuplicateTrackService.Candidate],
        destination: DuplicateTrackService.Destination?,
        context: ModelContext
    ) async throws -> String {
        let target = try DuplicateTrackService.validate(selected, destination: destination, in: context)
        if target == .otp, !selected.contains(where: { $0.destination == .otp }) {
            try await DuplicateTrackService.prepareOTPMembership(selected, in: context)
        }
        _ = try DuplicateTrackService.validate(selected, destination: target, in: context)
        if let current = currentPlaylistItem, selected.contains(where: { $0.itemID == current.id }) {
            settleSessionBeforeMoving(current)
        }
        let result = try DuplicateTrackService.merge(selected, destination: target, in: context)
        applyDuplicateMerge(result, context: context)
        var message = "Merged tracks. Play and skip counts were combined."
        if let otp = result.previousOTP, !result.remoteRemovalIDs.isEmpty {
            if !otp.allowsRemoteWrites { return message + " The playlist is incoming only; Apple Music was unchanged." }
            let itemID = result.itemID
            let locationDate = (try PlaylistItemRepository.item(id: itemID, in: context))?.locationChangedAt
            do {
                for musicID in result.remoteRemovalIDs {
                    _ = try await PlaylistSyncService().removeTrackFromPlaylist(
                        trackID: musicID, playlistID: otp.musicPlaylistID, isCurrent: {
                            let fresh = ModelContext(context.container)
                            guard let item = try? PlaylistItemRepository.item(id: itemID, in: fresh),
                                  let liveOTP = try? PlaylistRepository.playlist(id: otp.id, in: fresh),
                                  liveOTP.role == .oneTruePlaylist, liveOTP.allowsRemoteWrites else { return false }
                            return item.locationChangedAt == locationDate && item.suppressedOTPMusicPlaylistIDs.contains(otp.musicPlaylistID)
                        })
                }
            } catch {
                message += " Apple Music removal failed: \(error.localizedDescription)"
            }
        }
        return message
    }

    /// Identity merges rewrite member track UUIDs in the intent; the live
    /// queue is untouched.
    func applyDuplicateMerge(_ result: DuplicateTrackService.Result, context: ModelContext) {
        rekeyIntent(result.mapping)
        reconcileTrackMembership(context: context)
    }

    func rekeyIntent(_ mapping: [String: String]) {
        guard var intent, !mapping.isEmpty else { return }
        // Collapsed members keep every identifier, so entries queued under
        // the donor still attribute to the keeper.
        var merged: [PlaybackIntent.Member] = []
        for var member in intent.members {
            member.localTrackID = mapping[member.localTrackID] ?? member.localTrackID
            if let index = merged.firstIndex(where: { $0.localTrackID == member.localTrackID }) {
                merged[index].musicItemIDs += member.musicItemIDs.filter { !merged[index].musicItemIDs.contains($0) }
            } else {
                merged.append(member)
            }
        }
        intent.members = merged
        intent.startingLocalTrackID = intent.startingLocalTrackID.map { mapping[$0] ?? $0 }
        self.intent = intent
        attribution = PlaybackAttribution(intent: intent)
        attributedEntries = attributedEntries.mapValues { mapping[$0] ?? $0 }
        if let localID = session?.play.localTrackID { session?.play.localTrackID = mapping[localID] ?? localID }
        if let carried = session?.carriedLocalTrackID { session?.carriedLocalTrackID = mapping[carried] ?? carried }
        if let localID = pendingCarriedSession?.play.localTrackID {
            pendingCarriedSession?.play.localTrackID = mapping[localID] ?? localID
        }
        currentMember = intent.member(localTrackID: currentMember.map { mapping[$0.localTrackID] ?? $0.localTrackID })
        try? intentStore.save(intent)
        // The resume point names the track too; keep it on the same song.
        saveResumePoint(force: true)
    }

    /// MusicKit can report a new library playlist ID; the intent follows it.
    func rekeyIntentPlaylist(from oldID: String, to newID: String) {
        guard var intent, intent.musicPlaylistID == oldID, oldID != newID else { return }
        intent.musicPlaylistID = newID
        self.intent = intent
        try? intentStore.save(intent)
    }

    /// Refreshes Overplay data after any durable membership or count change.
    func reconcileTrackMembership(context: ModelContext) {
        adopt(context)
        refreshCurrentItem()
        applyDisplay(entry: player.currentEntry, member: currentMember)
        rebuildActivePlaylistSnapshot()
        bumpMetadataVersion()
    }

    /// Sync completion: refresh the projection. Additions wait for the next
    /// playback start (`PLAY-015`).
    func reconcileStoredOrder(for playlist: PlaylistRecord, context: ModelContext) {
        reconcileTrackMembership(context: context)
    }

    /// A new One True Playlist demotes the playing playlist; its rows move to
    /// the bucket, so the intent follows them. The live queue is unchanged.
    func reconcilePlaylistSelection(context: ModelContext) {
        adopt(context)
        guard var intent,
              let previous = try? PlaylistRepository.playlist(musicPlaylistID: intent.musicPlaylistID, in: context),
              previous.role == .triageSource,
              let bucket = try? PlaylistRepository.existingTriageBucket(in: context) else { return }
        intent.musicPlaylistID = bucket.musicPlaylistID
        self.intent = intent
        try? intentStore.save(intent)
        reconcileTrackMembership(context: context)
    }

    func refreshPlayCountMetadata(context: ModelContext) {
        reconcileTrackMembership(context: context)
    }

    private func settleSessionBeforeMoving(_ item: PlaylistItemRecord) {
        guard item.trackID.uuidString == currentMember?.localTrackID else { return }
        evaluatePlaythroughIfNeeded()
    }

    private func removeEvictedItemFromPlaylist(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async {
        guard item.evictedAt != nil else { return }
        guard PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(item: item, playlist: playlist) else {
            statusMessage = "Retired locally. \(playlist.name) is incoming only, so Apple Music was not changed."
            return
        }
        let track = try? TrackRecordRepository.track(id: item.trackID, in: context)
        guard let trackID = track?.catalogID ?? track?.libraryID else { return }
        let itemID = item.id
        let playlistID = playlist.id
        let locationChangedAt = item.locationChangedAt
        let container = context.container
        do {
            let removed = try await PlaylistSyncService().removeTrackFromPlaylist(
                trackID: trackID, playlistID: playlist.musicPlaylistID,
                isCurrent: {
                    let fresh = ModelContext(container)
                    guard let liveItem = try? PlaylistItemRepository.item(id: itemID, in: fresh),
                          let livePlaylist = try? PlaylistRepository.playlist(id: playlistID, in: fresh) else { return false }
                    return liveItem.evictedAt != nil && liveItem.locationChangedAt == locationChangedAt
                        && PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(item: liveItem, playlist: livePlaylist)
                }
            )
            if removed { statusMessage = "Removed \(track?.title ?? "track") from the Apple Music playlist." }
        } catch {
            statusMessage = "Retired locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
        }
    }

    /// `PLAY-015`: an entry whose member left the intent's scope is skipped
    /// when it becomes current, rather than mutating the queue in advance.
    private func skipIfMemberLeftScope(entry: PlayerEntrySnapshot) async {
        guard let member = currentMember, intent != nil, scopeCheckedVisitEntryID != entry.entryID,
              !skippedEntryIDs.contains(entry.entryID),
              let context = countingContext(), let trackID = UUID(uuidString: member.localTrackID) else { return }
        // Only a definite answer skips: a failed fetch is not "out of scope".
        var item: PlaylistItemRecord?
        do {
            item = try PlaylistItemRepository.item(trackID: trackID, in: context)
            if item == nil {
                if let keeper = try ListenLedger.keeper(absorbing: trackID, in: context) {
                    // Merged on another device: follow the surviving track.
                    rekeyIntent([trackID.uuidString: keeper.uuidString])
                    refreshCurrentItem()
                    applyDisplay(entry: entry, member: currentMember)
                    item = try PlaylistItemRepository.item(trackID: keeper, in: context)
                } else if try TrackRecordRepository.track(id: trackID, in: context) == nil {
                    // No item, no track and no lineage yet: a merge still
                    // arriving from another device. Unknown, so no skip, and
                    // the entry is checked again on its next attribution.
                    return
                }
            }
        } catch {
            return
        }
        scopeCheckedVisitEntryID = entry.entryID
        if let item, let intent, intent.scope.includes(item) { return }
        skippedEntryIDs.insert(entry.entryID)
        markSessionEvaluatedWithoutSkip()
        MusicKitActivityLog.shared.record(.playbackSelectionPath, detail: "skipOnReach")
        try? await player.skipToNextEntry()
        await observePlayer()
    }

    // MARK: - Display

    private func applyDisplay(entry: PlayerEntrySnapshot?, member: PlaybackIntent.Member?) {
        let item = currentPlaylistItem
        var track: CurrentPlaybackTrack?
        if let reported = entry?.item {
            track = CurrentPlaybackTrack(
                id: reported.id,
                title: reported.title,
                artistName: reported.artistName,
                albumTitle: reported.albumTitle,
                artworkURLTemplate: reported.artworkURLTemplate,
                durationSeconds: reported.durationSeconds ?? member?.durationSeconds
            )
            if let member, let portable = PortableArtworkReference.validated(member.artworkURLTemplate) {
                track?.artworkURLTemplate = portable
            }
        } else if let member {
            track = CurrentPlaybackTrack(
                id: member.musicItemIDs.first ?? member.localTrackID,
                title: member.title,
                artistName: member.artistName,
                albumTitle: member.albumTitle,
                artworkURLTemplate: member.artworkURLTemplate,
                durationSeconds: member.durationSeconds
            )
        } else if let entry {
            track = CurrentPlaybackTrack(id: entry.entryID, title: "Loading…", artistName: "")
        }
        if member != nil, let item {
            track?.skipCount = item.skipCount
            track?.playthroughCount = item.playthroughCount
            track?.applePlayCount = item.applePlayCount
            track?.evictedAt = item.evictedAt
        }
        if track != currentTrack {
            currentTrack = track
            bumpMetadataVersion()
        }
        durationSeconds = track?.durationSeconds
        if let track { prefetchArtwork(track) }
    }

    private func refreshCurrentItem() {
        guard let member = currentMember, let context = countingContext(), let trackID = UUID(uuidString: member.localTrackID) else {
            if currentMember == nil { currentPlaylistItem = nil }
            return
        }
        currentPlaylistItem = try? PlaylistItemRepository.item(trackID: trackID, in: context)
    }

    private func prefetchArtwork(_ track: CurrentPlaybackTrack) {
        guard prefetchedArtworkTrackID != track.id, let template = track.artworkURLTemplate else { return }
        prefetchedArtworkTrackID = track.id
        let playlistID = currentPlaylistID
        Task(priority: .userInitiated) {
            await ArtworkCacheService.shared.artworkFileURL(
                for: template, pixelSize: 512, playlistID: playlistID, priority: .userInitiated, protectedPlaylistID: nil
            )
        }
    }

    private func prioritizeUnknownApplePlayCount() {
        guard isPlaying, let item = currentPlaylistItem, item.applePlayCount == nil, let context = countingContext() else { return }
        let trackID = item.trackID
        guard appleCountLookupTrackID != trackID || appleCountLookupTask == nil else { return }
        appleCountLookupTask?.cancel()
        appleCountLookupTrackID = trackID
        appleCountLookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let changed: Int
            if let refreshUnknownApplePlayCount {
                changed = await refreshUnknownApplePlayCount(trackID, context)
            } else {
                changed = await ApplePlayCountSyncService.shared.refreshCurrentTrack(trackID, in: context)
            }
            guard !Task.isCancelled else { return }
            if changed > 0 { self.refreshPlayCountMetadata(context: context) }
            self.appleCountLookupTask = nil
        }
    }

    // MARK: - Active playlist projection

    private func rebuildActivePlaylistSnapshot() {
        guard let context = countingContext(), let playlist = try? currentPlaylist(in: context) else {
            activePlaylistSnapshot = nil
            return
        }
        do {
            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
            let candidate = ActivePlaylistSnapshot(
                playlist: playlist,
                items: items,
                tracks: tracks,
                playbackScope: currentPlaylistScope,
                currentPlaylistItemID: currentPlaylistItem?.id,
                currentLocalTrackID: currentMember?.localTrackID,
                currentMusicItemID: nil
            )
            if let previous = activePlaylistSnapshot, previous.playlistID == candidate.playlistID,
               previous.playbackScope == candidate.playbackScope, previous.rows == candidate.rows {
                return
            }
            activePlaylistSnapshot = candidate
        } catch {
            statusMessage = "Playback is active, but refreshing the visible playlist failed: \(error.localizedDescription)"
        }
    }

    private func patchActivePlaylistSnapshotRow(for item: PlaylistItemRecord) {
        guard let snapshot = activePlaylistSnapshot, snapshot.musicPlaylistID == currentPlaylistID,
              let patched = snapshot.updatingRow(for: item) else {
            rebuildActivePlaylistSnapshot()
            return
        }
        activePlaylistSnapshot = patched
    }

    private func updateActivePlaylistSnapshotCurrentRow() {
        guard let snapshot = activePlaylistSnapshot else {
            rebuildActivePlaylistSnapshot()
            return
        }
        let updated = snapshot.updatingCurrentRow(
            currentPlaylistItemID: currentPlaylistItem?.id,
            currentLocalTrackID: currentMember?.localTrackID,
            currentMusicItemID: nil
        )
        if updated != snapshot { activePlaylistSnapshot = updated }
    }

    // MARK: - Suspended-playback reconciliation hooks

    func capturePlaybackObservation(context: ModelContext) -> PlaybackReconciliationPolicy.Observation? {
        observeModes()
        guard let intent, let entry = player.currentEntry,
              let member = member(for: entry) ?? attribution?.member(localTrackID: attributedEntries[entry.entryID]) else {
            return nil
        }
        let duration = UUID(uuidString: member.localTrackID)
            .flatMap { try? TrackRecordRepository.track(id: $0, in: context) }?.durationSeconds ?? member.durationSeconds
        return PlaybackReconciliationPolicy.Observation(
            playlistID: intent.musicPlaylistID,
            localTrackID: member.localTrackID,
            positionSeconds: player.playbackTime,
            durationSeconds: duration,
            observedAt: .now
        )
    }

    /// The submitted order. It is the played order only while shuffle is
    /// confirmed off, which the caller checks separately.
    func capturePlaybackOrder(context: ModelContext) -> [PlaybackReconciliationPolicy.OrderedTrack] {
        intent?.members.map {
            PlaybackReconciliationPolicy.OrderedTrack(localTrackID: $0.localTrackID, durationSeconds: $0.durationSeconds)
        } ?? []
    }

    func markActiveSessionPlaythroughCounted(localTrackID: String) {
        guard session?.play.localTrackID == localTrackID else { return }
        session?.play.hasEvaluated = true
    }

    func activeSessionHasEvaluated(localTrackID: String) -> Bool {
        session?.play.localTrackID == localTrackID && session?.play.hasEvaluated == true
    }

    func publishReconciledPlaylistItemChanges(localTrackIDs: [String], playlistID: String, context: ModelContext) {
        guard currentPlaylistID == playlistID, !localTrackIDs.isEmpty else { return }
        reconcileTrackMembership(context: context)
    }

    // MARK: - Helpers

    /// The container's main context wins over any short-lived context a
    /// background wake or import handler happens to pass first.
    private func adopt(_ context: ModelContext) {
        if self.context == nil || (context === context.container.mainContext && self.context !== context) {
            self.context = context
            cachedSettings = nil
        }
    }

    /// Ledger writes and item reads wait for library restoration.
    private func countingContext() -> ModelContext? {
        guard isLibraryReady() else { return nil }
        return context
    }

    private func settings(in context: ModelContext) -> OverplaySettings? {
        if let cachedSettings, !cachedSettings.isDeleted { return cachedSettings }
        cachedSettings = try? SettingsRepository.settings(in: context)
        return cachedSettings
    }

    private func currentPlaylist(in context: ModelContext) throws -> PlaylistRecord? {
        try PlaybackTrackResolver.currentPlaylist(musicPlaylistID: currentPlaylistID, in: context)
    }

    private func saveResumePoint(force: Bool, now: Date = .now) {
        guard let intent else { return }
        if !force, let last = lastResumeSaveAt, now.timeIntervalSince(last) < Self.resumeSaveInterval { return }
        lastResumeSaveAt = now
        intentStore.save(PlaybackResumePoint(
            intentID: intent.id,
            localTrackID: currentMember?.localTrackID,
            positionSeconds: elapsedSeconds,
            wasPlaying: isPlaying,
            updatedAt: now
        ))
    }

    private func updateRetentionLease() {
        let protecting = session?.play.hasEvaluated == false
        retentionLease.itemID = protecting ? currentPlaylistItem?.id : nil
        retentionLease.trackID = protecting ? currentPlaylistItem?.trackID : nil
    }

    private func bumpMetadataVersion() {
        playbackItemMetadataVersion += 1
    }

    private static func describe<T>(_ value: T?) -> String {
        value.map { String(describing: $0) } ?? "nil"
    }
}
