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
        /// Attributed to a song Overplay tracks. An album or artist intent
        /// also plays songs it does not, which are never counted (`PLAY-018`).
        var isTracked: Bool { play.localTrackID.flatMap(UUID.init(uuidString:)) != nil }
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
    /// Prepares tracks for playback; the set names tracks to resolve again
    /// even when cached.
    @ObservationIgnored private let preparePlaybackTracks: @MainActor ([TrackRecord], Set<UUID>) async throws -> Void
    @ObservationIgnored private let refreshUnknownApplePlayCount: (@MainActor (UUID, ModelContext) async -> Int)?
    @ObservationIgnored var isLibraryReady: @MainActor () -> Bool = { true }
    /// Apple Music membership of the One True Playlist (`PLAYLIST-008`); injectable for tests.
    @ObservationIgnored var remoteMembership = OneTruePlaylistRemoteMembership()
    /// Rebuilds the One True Playlist's Apple Music playlist (`PLAYLIST-009`); injectable for tests.
    @ObservationIgnored var playlistRebuild = OneTruePlaylistRebuildService()
    /// The Apple Music catalog behind Play Album and Play Artist (`PLAY-018`); injectable for tests.
    @ObservationIgnored var playbackCatalog = PlaybackCatalog.live
    /// Album and artist songs' native tracks on this device (`PLAY-019`); injectable for tests.
    @ObservationIgnored var collectionTrackCache = DevicePlaybackCache.shared
    /// Adds a catalog song to an Apple Music playlist; injectable for tests.
    @ObservationIgnored var addCatalogSongToPlaylist: @MainActor (String, PlaylistRecord, ModelContext) async throws -> Void = {
        try await PlaylistMutationService().addCatalogSong(id: $0, to: $1, in: $2)
    }
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    /// Where the controller's decisions are recorded; injectable for tests.
    @ObservationIgnored var activityLog = MusicKitActivityLog.shared

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
    /// Every start loads the queue before playing (#76). While MusicKit loads,
    /// it reports track 1 as current, even playing, until it reaches the start
    /// entry. Until play starts those interim entries are not observed: never
    /// shown, never a session. The hold belongs to one start and ends when it
    /// plays, when a newer start replaces it, when the user presses Play, or
    /// at the limit.
    @ObservationIgnored private var startHold: Int?
    /// The start whose held observation has been recorded, so it is listed once.
    @ObservationIgnored private var recordedHeldStart: Int?
    /// The display last recorded, so only changes are listed.
    @ObservationIgnored private var recordedDisplay: String?
    private var isHoldingStart: Bool { startHold == startGeneration }
    /// How long the hold may last if Apple Music never finishes preparing.
    @ObservationIgnored var startHoldLimit: Duration = .seconds(8)
    /// The longest a start waits for MusicKit to load the queue.
    @ObservationIgnored var queueLoadLimit: Duration = .seconds(3)
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
        preparePlaybackTracks: @escaping @MainActor ([TrackRecord], Set<UUID>) async throws -> Void = {
            try await DevicePlaybackCache.prepare($0, refreshing: $1)
        },
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
    /// The playback context of an album or artist intent (`PLAY-018`).
    var playbackCollectionTitle: String? { intent?.collection?.contextTitle }
    /// The Recents entry being played, if any (`PLAY-019`).
    var playingCollectionGroupKey: String? { intent?.collection?.groupKey }
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
        guard !isHoldingStart else {
            if recordedHeldStart != startHold {
                recordedHeldStart = startHold
                activityLog.record(.observationHeld, detail: "start=\(startGeneration) entry=\(player.currentEntryID ?? "nil")")
            }
            return
        }
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
                recordEntry(entry, path: "hydrated")
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
        activityLog.record(.playerModeObserved, detail: "shuffle=\(Self.describe(modes.shuffle)) repeat=\(Self.describe(modes.repeatMode))")
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
        recordEntry(entry, path: "new")
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
        activityLog.record(.playbackSelectionPath, detail: "sessionCarriedOver confirmed=\(confirmed)")
        await attributeCurrent(entry)
        recordEntry(entry, path: "carried")
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
            activityLog.record(.queueCorrelationRejected,
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

    /// What the controller made of an entry change, so a display that stops
    /// following the audio can be explained from the device log (#84).
    private func recordEntry(_ entry: PlayerEntrySnapshot, path: String) {
        let item = entry.item.map { "\"\($0.title)\"" } ?? "unhydrated"
        let member = currentMember.map { "\"\($0.title)\"" } ?? "none"
        activityLog.record(.playerEntryObserved, detail:
            "\(path) entry=\(entry.entryID) item=\(item) member=\(member) position=\(Int(player.playbackTime)) status=\(player.playbackStatus)")
    }

    /// Records a player call before waiting on it. The player wrapper records
    /// only completions, so a call that never returns shows as a start with
    /// no completion (#84).
    private func awaitPlayer(_ call: String, _ body: () async throws -> Void) async throws {
        activityLog.record(.playerCallStarted, detail: call)
        try await body()
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
        activityLog.record(.queueEndObserved,
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
        guard let current = session, current.isTracked, !current.play.hasEvaluated,
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
                playlist: try countingPlaylist(for: current, in: context),
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
        guard ended.isTracked else { return }
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
                playlist: try countingPlaylist(for: ended, in: context),
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

    /// The playlist a listen is credited to: the one playing, or for an album
    /// or artist intent the one that owns the song (`PLAY-018`).
    private func countingPlaylist(for session: ObservedSession, in context: ModelContext) throws -> PlaylistRecord? {
        guard intent?.collection != nil else { return try currentPlaylist(in: context) }
        guard let item = item(for: session, in: context) else { return nil }
        return try PlaylistRepository.playlist(id: item.playlistID, in: context)
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
        // Play takes over from a start still preparing.
        startHold = nil
        if playbackFailure != nil {
            await recover()
        } else if player.currentEntryID != nil {
            do {
                try await awaitPlayer("play resume") { try await player.play() }
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
            activityLog.record(.playbackSelectionPath, detail: "newIntent")
            await startPlayback(playlist, scope: scope, startingTrackID: localTrackID, shuffle: false, context: context)
            return
        }
        await select(member, in: intent)
    }

    /// Selecting a member of the live intent, for playlists and Recents alike
    /// (`SURFACE-003`): the current song resumes, never restarts; another is
    /// selected in the live queue; one the queue no longer holds is
    /// resubmitted from.
    private func select(_ member: PlaybackIntent.Member, in intent: PlaybackIntent) async {
        let localTrackID = member.localTrackID
        if currentMember?.localTrackID == localTrackID {
            // The current track resumes, never restarts, live queue or not.
            activityLog.record(.playbackSelectionPath, detail: "resumeCurrent")
            if let context, player.currentEntryID == nil || player.playbackStatus != .playing { await play(context: context) }
            return
        }

        if let entryID = liveEntryID(for: member) {
            activityLog.record(.playbackSelectionPath, detail: "inIntentJump")
            startGeneration &+= 1
            do {
                try player.selectEntry(withID: entryID)
                try await awaitPlayer("play jump") { try await player.play() }
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
        activityLog.record(.playbackSelectionPath, detail: "resubmitFromMember")
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
            // Shuffle picks the song: the queue starts in playlist order.
            startIndex = 0
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
            startingLocalTrackID: shuffle ? nil : playable[startIndex].0.localTrackID
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
    private func resubmit(
        _ intent: PlaybackIntent, from member: PlaybackIntent.Member?, position: Double, refreshingStart: Bool = false
    ) async {
        startGeneration &+= 1
        let generation = startGeneration
        let resolved: [String: Track]
        if intent.collection != nil {
            // An album or artist is looked up in the catalog again (`PLAY-018`).
            resolved = await resolveCollectionTracks(intent.members)
        } else {
            let records = intent.members.compactMap { member -> TrackRecord? in
                guard let id = member.trackID, let context = countingContext() else { return nil }
                return try? TrackRecordRepository.track(id: id, in: context)
            }
            var refreshing: Set<UUID> = []
            if refreshingStart, let id = member?.trackID { refreshing.insert(id) }
            let tracks = await resolvePlayableTracks(records, refreshing: refreshing,
                                                     fallbackLocalTrackIDs: intent.members.map(\.localTrackID))
            resolved = intent.members.reduce(into: [:]) { result, member in
                if let id = member.trackID, let track = tracks[id] { result[member.localTrackID] = track }
            }
        }
        guard generation == startGeneration else { return }
        let playable = intent.members.compactMap { member -> (PlaybackIntent.Member, Track)? in
            resolved[member.localTrackID].map { (member, $0) }
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
        elapsedSeconds = position
        if shuffle {
            // The song is chosen by shuffle; it is shown once observed.
            currentMember = nil
        } else {
            currentMember = intent.members.indices.contains(startIndex) ? intent.members[startIndex] : intent.members.first
            applyDisplay(entry: nil, member: currentMember)
        }
        refreshCurrentItem()
        rebuildActivePlaylistSnapshot()

        player.pause()
        player.submitQueue(tracks, startingAt: startIndex)
        do {
            try await startLoaded(trackCount: tracks.count, shuffle: shuffle, generation: generation)
            // A newer start replaced this queue while play was in flight.
            guard generation == startGeneration else { return }
            if let duration = currentMember?.durationSeconds, position > 5, position < duration - 5 {
                player.playbackTime = position
            }
            clearFailure()
            statusMessage = nil
        } catch {
            guard generation == startGeneration else { return }
            fail(error)
        }
        saveResumePoint(force: true)
    }

    /// Every start (#76): load the queue without playing, wait until MusicKit
    /// has loaded every entry, then play. Played sooner, MusicKit reports and
    /// briefly plays track 1 until it reaches the start entry (device probe,
    /// 2026-10-07). Shuffle and Play also enables shuffle on the loaded queue
    /// and skips to a random song first; shuffle written earlier mixes only
    /// the first few songs. Nothing is heard or shown before the chosen song.
    private func startLoaded(trackCount: Int, shuffle: Bool, generation: Int) async throws {
        startHold = generation
        // The player was paused for this start; never offer Pause meanwhile.
        isPlaying = false
        // On 2026-10-07 prepareToPlay never returned, and the hold left the
        // controller believing it was playing until relaunch.
        let watchdog = Task { [weak self, limit = startHoldLimit] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.startHold == generation else { return }
            // Stop hiding the player; Play recovers as usual, and a late
            // prepare does not resume this start.
            self.startHold = nil
            activityLog.record(.playbackSelectionPath, detail: "startTimedOut")
            await self.observePlayer()
        }
        defer {
            watchdog.cancel()
            if startHold == generation { startHold = nil }
        }
        try await awaitPlayer("prepare start=\(generation)") { try await player.prepareToPlay() }
        guard isHoldingStart(generation) else { return }
        // Nothing is playing yet; past the limit, start anyway.
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: queueLoadLimit)
        while player.loadedEntryCount < trackCount, clock.now < limit {
            try? await Task.sleep(for: .milliseconds(50))
            guard isHoldingStart(generation) else { return }
        }
        guard isHoldingStart(generation) else { return }
        if shuffle {
            player.setShuffleMode(.off)
            player.setShuffleMode(.songs)
            if trackCount > 1 { try await player.skipToNextEntry() }
            guard isHoldingStart(generation) else { return }
        }
        try await awaitPlayer("play start=\(generation)") { try await player.play() }
    }

    private func isHoldingStart(_ generation: Int) -> Bool {
        generation == startGeneration && startHold == generation
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
    private func resolvePlayableTracks(
        _ records: [TrackRecord], refreshing: Set<UUID> = [], fallbackLocalTrackIDs: [String] = []
    ) async -> [UUID: Track] {
        if !records.isEmpty {
            do {
                try await preparePlaybackTracks(records, refreshing)
            } catch {
                // Name the songs left out where they can be seen: the activity
                // report and the unified log at normal level (#75).
                activityLog.record(
                    .playbackQueuePreparation, detail: error.localizedDescription, error: error
                )
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

    private func resolveCollectionTracks(_ members: [PlaybackIntent.Member]) async -> [String: Track] {
        let songs = await collectionTracks(members.compactMap(\.catalogSongID))
        var resolved: [String: Track] = [:]
        for member in members {
            if let id = member.catalogSongID, let track = songs[id], Self.isQueueable(track) {
                resolved[member.localTrackID] = track
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

    // MARK: - Album and artist (`PLAY-018`)

    /// The current song's catalog ID, which Play Album and Play Artist look up.
    var currentCatalogSongID: String? {
        if let catalogSongID = currentMember?.catalogSongID { return catalogSongID }
        let ids = currentMember?.musicItemIDs ?? player.currentEntry?.item.map { $0.identifiers.sorted() } ?? []
        return ids.first { !$0.isEmpty && !MusicTrackIdentity.isLibraryID($0) }
    }

    var canPlayCurrentCollection: Bool { currentTrack != nil && currentCatalogSongID != nil }

    /// Play Album or Play Artist for the current song, the one action every
    /// surface uses. It looks the songs up, then starts a new intent through
    /// the shared start path. A failed lookup changes nothing and is reported
    /// through `statusMessage`. Returns whether playback started.
    @discardableResult
    func playCurrentCollection(_ request: PlaybackCollection.Request, context: ModelContext) async -> Bool {
        adopt(context)
        guard let songID = currentCatalogSongID else {
            statusMessage = PlaybackCollectionError.songNotInCatalog.localizedDescription
            return false
        }
        activityLog.record(.playbackSelectionPath, detail: "playCollection request=\(request.rawValue)")
        // Nothing is replaced until the lookup succeeds, so a start in
        // progress is not disturbed by one that fails.
        let generationBeforeLookup = startGeneration
        let contents: PlaybackCollectionContents
        do {
            contents = try await playbackCatalog.collection(request, songID)
        } catch {
            if startGeneration == generationBeforeLookup { statusMessage = Self.collectionFailureMessage(request, error) }
            return false
        }
        // A newer start or selection happened during the lookup.
        guard startGeneration == generationBeforeLookup else { return false }
        let playable = collectionPlayable(contents.tracks.filter(Self.isQueueable))
        guard !playable.isEmpty else {
            statusMessage = Self.collectionFailureMessage(request, PlaybackCollectionError.empty)
            return false
        }
        let started = await startCollection(contents.collection, playable: playable, startIndex: 0, shuffle: false)
        if started {
            let songs = playable.map { Self.savedSong($0.0) }
            recordRecent(contents.collection, songs: songs,
                         artworkURLTemplate: contents.artworkURLTemplate ?? songs.first?.artworkURLTemplate)
        }
        return started
    }

    /// Plays a Recents entry from its saved songs, from any surface
    /// (`PLAY-019`). Shuffle and Play when `catalogSongID` is nil; otherwise
    /// the same selection rules as a playlist (`SURFACE-003`): the current song
    /// resumes, a song in the live intent is selected in place, and anything
    /// else starts the entry at that song. Songs this device has not played
    /// are looked up once; a failed lookup changes nothing.
    @discardableResult
    func playRecent(_ recent: RecentCollectionRecord, startingAt catalogSongID: String?, context: ModelContext) async -> Bool {
        adopt(context)
        let collection = recent.collection
        let songs = recent.songs
        let shuffle = catalogSongID == nil
        if let catalogSongID, let intent, intent.collection?.groupKey == collection.groupKey,
           let member = intent.members.first(where: { $0.catalogSongID == catalogSongID }) {
            await select(member, in: intent)
            recordRecent(collection, songs: songs, artworkURLTemplate: nil)
            return playbackFailure == nil
        }
        activityLog.record(.playbackSelectionPath, detail: "playRecent \(collection.groupKey) shuffle=\(shuffle)")
        let generationBeforeLookup = startGeneration
        let resolved = await collectionTracks(songs.map(\.catalogID))
        guard startGeneration == generationBeforeLookup else { return false }
        let playable = collectionPlayable(songs.compactMap { resolved[$0.catalogID] })
        guard !playable.isEmpty else {
            statusMessage = "Couldn't play \(collection.title): Apple Music didn't return its songs. Check your connection."
            return false
        }
        var startIndex = 0
        if let catalogSongID {
            guard let index = playable.firstIndex(where: { $0.0.catalogSongID == catalogSongID }) else {
                statusMessage = "That song is unavailable in Apple Music right now."
                return false
            }
            startIndex = index
        }
        let started = await startCollection(collection, playable: playable, startIndex: startIndex, shuffle: shuffle)
        if started { recordRecent(collection, songs: songs, artworkURLTemplate: nil) }
        return started
    }

    private func startCollection(
        _ collection: PlaybackCollection, playable: [(PlaybackIntent.Member, Track)], startIndex: Int, shuffle: Bool
    ) async -> Bool {
        startGeneration &+= 1
        let generation = startGeneration
        let intent = PlaybackIntent(
            id: UUID(),
            createdAt: .now,
            musicPlaylistID: collection.reservedPlaylistID,
            scope: .active,
            members: playable.map(\.0),
            startingLocalTrackID: shuffle ? nil : playable[startIndex].0.localTrackID,
            collection: collection
        )
        await submit(intent, tracks: playable.map(\.1), startIndex: startIndex, position: 0, shuffle: shuffle,
                     generation: generation)
        await observePlayer()
        return generation == startGeneration && playbackFailure == nil
    }

    /// Recents are additive: a failure to record never affects playback.
    private func recordRecent(_ collection: PlaybackCollection, songs: [PlaybackCollectionSong], artworkURLTemplate: String?) {
        guard let context = countingContext(), !songs.isEmpty else { return }
        do {
            try RecentCollectionRepository.record(collection, songs: songs, artworkURLTemplate: artworkURLTemplate, in: context)
        } catch {
            TrackMetadataDiagnostics.log("recents record failed: \(error.localizedDescription)")
        }
    }

    private static func savedSong(_ member: PlaybackIntent.Member) -> PlaybackCollectionSong {
        PlaybackCollectionSong(
            catalogID: member.catalogSongID ?? member.localTrackID,
            title: member.title,
            artistName: member.artistName,
            albumTitle: member.albumTitle,
            artworkURLTemplate: member.artworkURLTemplate,
            durationSeconds: member.durationSeconds
        )
    }

    /// Native tracks for catalog songs: this device's cache first, then one
    /// catalog lookup for the rest, which are then cached (`PLAY-019`).
    private func collectionTracks(_ catalogIDs: [String]) async -> [String: Track] {
        var resolved: [String: Track] = [:]
        for id in catalogIDs {
            if let data = collectionTrackCache.data(forCatalogSongID: id),
               let track = try? JSONDecoder().decode(Track.self, from: data), Self.isQueueable(track) {
                resolved[id] = track
            }
        }
        let missing = catalogIDs.filter { resolved[$0] == nil }
        guard !missing.isEmpty else { return resolved }
        do {
            for (id, track) in try await playbackCatalog.songs(missing) where Self.isQueueable(track) {
                resolved[id] = track
                collectionTrackCache.set(try? JSONEncoder().encode(track), forCatalogSongID: id)
            }
        } catch {
            activityLog.record(.playbackQueuePreparation, detail: error.localizedDescription, error: error)
        }
        return resolved
    }

    static func collectionFailureMessage(_ request: PlaybackCollection.Request, _ error: Error) -> String {
        let what = request == .album ? "the album" : "the artist"
        return "Couldn't play \(what): \(error.localizedDescription)"
    }

    /// Members for catalog tracks, in order. A song Overplay tracks carries
    /// its track ID, so it is counted and curated as usual. Identity is by
    /// catalog ID only, never by title.
    private func collectionPlayable(_ tracks: [Track]) -> [(PlaybackIntent.Member, Track)] {
        let context = countingContext()
        let tracked = context.flatMap { try? TrackRecordRepository.tracksByCatalogID(in: $0) } ?? [:]
        var seen: Set<String> = []
        return tracks.compactMap { track in
            let catalogID = track.id.rawValue
            if collectionTrackCache.data(forCatalogSongID: catalogID) == nil {
                collectionTrackCache.set(try? JSONEncoder().encode(track), forCatalogSongID: catalogID)
            }
            var member: PlaybackIntent.Member
            if let record = tracked[catalogID], let context,
               let item = try? PlaylistItemRepository.item(trackID: record.id, in: context) {
                member = Self.member(for: record, item: item, track: track)
            } else {
                member = PlaybackIntent.Member(
                    localTrackID: PlaybackIntent.Member.untrackedID(catalogID: catalogID),
                    playlistItemID: nil,
                    musicItemIDs: [catalogID],
                    title: track.title,
                    artistName: track.artistName,
                    albumTitle: track.albumTitle,
                    artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
                    durationSeconds: track.duration
                )
            }
            member.catalogSongID = catalogID
            // A song the collection lists twice plays once.
            guard seen.insert(member.localTrackID).inserted else { return nil }
            return (member, track)
        }
    }

    /// The current song is one Overplay does not track, playing from an
    /// album or artist: it offers Add instead of curation.
    var canAddCurrentToOverplay: Bool {
        _ = playbackItemMetadataVersion
        guard intent?.collection != nil, let member = currentMember else { return false }
        return member.trackID == nil
    }

    /// Adding to the One True Playlist writes to Apple Music, so it needs a
    /// managed playlist.
    func canAddCurrentToOneTruePlaylist(context: ModelContext) -> Bool {
        canAddCurrentToOverplay && (try? PlaylistRepository.oneTruePlaylist(in: context))?.allowsRemoteWrites == true
    }

    func addCurrentToTriage(context: ModelContext) async {
        await addCurrent(toOneTruePlaylist: false, context: context)
    }

    func addCurrentToOneTruePlaylist(context: ModelContext) async {
        await addCurrent(toOneTruePlaylist: true, context: context)
    }

    /// The shared manual-add boundary: Triage is local with explicit keep;
    /// the One True Playlist is added in Apple Music first. Playback goes on,
    /// and counting starts with the song's next listening session.
    private func addCurrent(toOneTruePlaylist: Bool, context: ModelContext) async {
        adopt(context)
        guard canAddCurrentToOverplay, let member = currentMember, let catalogID = member.catalogSongID,
              let context = countingContext() else {
            statusMessage = "Only a song Overplay doesn't track yet can be added."
            return
        }
        let destination: PlaylistRecord
        do {
            if toOneTruePlaylist {
                guard let otp = try PlaylistRepository.oneTruePlaylist(in: context) else {
                    throw PlaylistMutationError.oneTruePlaylistMissing
                }
                guard otp.allowsRemoteWrites else { throw PlaylistMutationError.playlistIncomingOnly }
                destination = otp
            } else {
                destination = try PlaylistRepository.triageBucket(in: context)
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        let song = SearchSongResult(id: catalogID, title: member.title, artistName: member.artistName,
                                    albumTitle: member.albumTitle, artworkURL: member.artworkURLTemplate)
        let mutations = PlaylistMutationService()
        do {
            if toOneTruePlaylist { try await addCatalogSongToPlaylist(catalogID, destination, context) }
            let item = try mutations.recordSuccessfulManualAdd(song, to: destination, in: context)
            if session?.play.localTrackID == member.localTrackID { markSessionEvaluatedWithoutSkip() }
            rekeyIntent([member.localTrackID: item.trackID.uuidString])
            reconcileTrackMembership(context: context)
            statusMessage = toOneTruePlaylist ? "Added to the One True Playlist." : "Added to Triage."
        } catch {
            if toOneTruePlaylist {
                mutations.recordFailedManualAdd(song, to: destination, message: error.localizedDescription, in: context)
            }
            statusMessage = "Couldn't add \(member.title): \(error.localizedDescription)"
        }
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
        activityLog.record(.playbackRecoveryAttempt, magnitude: Double(firstRung), detail: "user play")
        resetStallEvidence()

        if firstRung <= 1, (try? await awaitPlayer("play recovery rung=1", { try await player.play() })) != nil {
            recovered(rung: 1, at: now)
            return
        }
        if firstRung <= 2, (try? await awaitPlayer("prepare recovery rung=2", { try await player.prepareToPlay() })) != nil,
           (try? await awaitPlayer("play recovery rung=2", { try await player.play() })) != nil {
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
        // The start track is looked up again, so cached play parameters that
        // MusicKit can no longer play are not resubmitted unchanged.
        recoveryEscalation = (3, now)
        let messageBefore = playbackFailure?.message
        let generation = startGeneration &+ 1
        await resubmit(intent, from: currentMember ?? intent.members.first, position: elapsedSeconds, refreshingStart: true)
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
            activityLog.record(.deliveryStallDetected, detail:
                "\(message) kind=\(kind) entry=\(lastEntryID ?? "nil") position=\(Int(elapsedSeconds)) status=\(player.playbackStatus)")
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

    /// `PLAYLIST-009`: one shared entry point for every surface offering it.
    func rebuildOneTruePlaylist(context: ModelContext) async throws -> OneTruePlaylistRebuildService.Result {
        adopt(context)
        let result = try await playlistRebuild.rebuild(in: context)
        reconcileTrackMembership(context: context)
        return result
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
            do {
                let outcome = try await remoteMembership.removeSongsHeldOutside(otp, in: context)
                if outcome.deferredItemIDs.contains(result.itemID) {
                    message += " Apple Music will be updated after the next sync."
                } else if outcome.refusedItemIDs.contains(result.itemID) {
                    message += " " + Self.editsRefusedMessage
                } else if outcome.notEditableHereItemIDs.contains(result.itemID) {
                    message += " " + Self.notEditableHereMessage
                }
                reconcileTrackMembership(context: context)
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

    static let editsRefusedMessage = "Retired. Apple Music won't let Overplay edit this playlist; rebuild it in Settings, or remove the song in the Music app."
    static let notEditableHereMessage = "Retired. Apple Music will be updated from your iPhone or iPad."

    /// Every One True Playlist retire, from any surface, removes the song from
    /// the Apple Music playlist (`PLAYLIST-008`). The local retirement stands
    /// whatever happens remotely.
    private func removeEvictedItemFromPlaylist(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async {
        guard item.evictedAt != nil else { return }
        guard PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction(item: item, playlist: playlist) else {
            statusMessage = "Retired locally. \(playlist.name) is incoming only, so Apple Music was not changed."
            return
        }
        let itemID = item.id
        let title = (try? TrackRecordRepository.track(id: item.trackID, in: context))?.title ?? "track"
        do {
            let outcome = try await remoteMembership.removeSongsHeldOutside(playlist, in: context)
            if outcome.removedItemIDs.contains(itemID) {
                statusMessage = "Removed \(title) from the Apple Music playlist."
            } else if outcome.deferredItemIDs.contains(itemID) {
                statusMessage = "Retired. Apple Music will be updated after the next sync."
            } else if outcome.refusedItemIDs.contains(itemID) {
                statusMessage = Self.editsRefusedMessage
            } else if outcome.notEditableHereItemIDs.contains(itemID) {
                statusMessage = Self.notEditableHereMessage
            }
        } catch {
            statusMessage = "Retired locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
        }
        reconcileTrackMembership(context: context)
    }

    /// `PLAY-015`: an entry whose member left the intent's scope is skipped
    /// when it becomes current, rather than mutating the queue in advance.
    private func skipIfMemberLeftScope(entry: PlayerEntrySnapshot) async {
        // An album or artist plays everything in it, retired songs included (`PLAY-018`).
        guard let member = currentMember, intent != nil, intent?.collection == nil, scopeCheckedVisitEntryID != entry.entryID,
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
        activityLog.record(.playbackSelectionPath, detail: "skipOnReach")
        try? await player.skipToNextEntry()
        await observePlayer()
    }

    // MARK: - Display

    private func applyDisplay(entry: PlayerEntrySnapshot?, member: PlaybackIntent.Member?) {
        // Membership refreshes from sync can land while the queue loads.
        guard !isHoldingStart else { return }
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
        let displayed = "\(track.map { "\"\($0.title)\" id=\($0.id)" } ?? "none") member=\(member != nil)"
        if displayed != recordedDisplay {
            recordedDisplay = displayed
            activityLog.record(.nowPlayingDisplayChanged, detail: displayed)
        }
        if track != currentTrack {
            currentTrack = track
            bumpMetadataVersion()
        }
        durationSeconds = track?.durationSeconds
        if let track { prefetchArtwork(track) }
    }

    private func refreshCurrentItem() {
        guard let member = currentMember, let context = countingContext() else {
            if currentMember == nil { currentPlaylistItem = nil }
            return
        }
        guard let trackID = member.trackID else {
            // A song Overplay does not track has no item (`PLAY-018`).
            currentPlaylistItem = nil
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
        // A stalled player still reports playing; no lookups during a failure (`LOAD-001`).
        guard isPlaying, playbackFailure == nil, let item = currentPlaylistItem, item.applePlayCount == nil,
              let context = countingContext() else { return }
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
        guard let intent, intent.collection == nil, let entry = player.currentEntry,
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
        guard intent?.collection == nil else { return [] }
        return intent?.members.map {
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
