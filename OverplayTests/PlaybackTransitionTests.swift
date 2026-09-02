import Foundation
import enum MediaPlayer.MPRemoteCommandHandlerStatus
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Player-confirmed playback transitions", .serialized)
struct PlaybackTransitionTests {
    @Test("confirmation policy never advances an unchanged or missing entry")
    func confirmationPolicyNeverAdvancesAnUnchangedOrMissingEntry() {
        let policy = PlaybackTransitionConfirmationPolicy(
            maximumObservationCount: 3,
            observationInterval: .zero
        )

        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: "outgoing"
        ) == .waiting)
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: nil
        ) == .waiting)
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: "incoming"
        ) == .confirmed(entryID: "incoming"))
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: ["expected"],
            observedEntryID: "external"
        ) == .diverged(entryID: "external"))
    }

    @Test("delayed Next keeps every published surface on outgoing until confirmation")
    func delayedNextKeepsPublishedStateOnOutgoingUntilConfirmation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.nextConfirmationDelays = [2]
        fixture.sleepProbe.handler = {
            fixture.sleepProbe.observedTrackIDs.append(fixture.controller.currentTrack?.id)
            fixture.sleepProbe.observedRestoreTrackIDs.append(LocalPlaybackStateStore.load()?.musicItemID)
            fixture.sleepProbe.observedCurrentRowTrackIDs.append(
                fixture.controller.activePlaylistSnapshot?.rows.first(where: \.isCurrent)?.localTrackID
            )
        }

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.sleepProbe.observedTrackIDs == [fixture.musicTracks[0].id.rawValue, fixture.musicTracks[0].id.rawValue])
        #expect(fixture.sleepProbe.observedRestoreTrackIDs == [fixture.musicTracks[0].id.rawValue, fixture.musicTracks[0].id.rawValue])
        #expect(fixture.sleepProbe.observedCurrentRowTrackIDs == [fixture.tracks[0].id.uuidString, fixture.tracks[0].id.uuidString])
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(fixture.items[1].skipCount == 0)
        #expect(try fixture.history().count == 1)
    }

    @Test("failed and timed-out Next preserve identity and commit no history")
    func failedAndTimedOutNextPreserveIdentityAndCommitNoHistory() async throws {
        let failed = try makeFixture()
        defer { failed.cleanUp() }
        try await failed.start(at: 0)
        failed.player.playbackTime = 15
        await failed.controller.reconcilePlayerState(context: failed.context)
        failed.player.nextFailuresRemaining = 1

        await failed.controller.next(settings: failed.settings, context: failed.context)

        #expect(failed.controller.currentTrack?.id == failed.musicTracks[0].id.rawValue)
        #expect(failed.items[0].skipCount == 0)
        #expect(try failed.history().isEmpty)
        #expect(failed.controller.isDeliveryStalled)
        #expect(failed.controller.remoteCommandAvailability.canPlay)
        #expect(!failed.controller.remoteCommandAvailability.canPause)

        let timedOut = try makeFixture(maximumObservationCount: 3)
        defer { timedOut.cleanUp() }
        try await timedOut.start(at: 0)
        timedOut.player.playbackTime = 15
        await timedOut.controller.reconcilePlayerState(context: timedOut.context)
        timedOut.player.nextConfirmationDelays = [100]

        await timedOut.controller.next(settings: timedOut.settings, context: timedOut.context)

        #expect(timedOut.controller.currentTrack?.id == timedOut.musicTracks[0].id.rawValue)
        #expect(timedOut.items[0].skipCount == 0)
        #expect(try timedOut.history().isEmpty)
        #expect(timedOut.controller.statusMessage == PlaybackTransitionError.confirmationTimedOut.localizedDescription)
    }

    @Test("Next does not confirm when a temporarily missing outgoing entry reappears unchanged")
    func temporarilyMissingOutgoingEntryDoesNotConfirmUnchangedNext() async throws {
        let fixture = try makeFixture(maximumObservationCount: 3)
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.suppressCurrentEntryReporting = true
        fixture.player.nextRevealsUnchangedEntry = true

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.nextCallCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
        #expect(fixture.controller.statusMessage == PlaybackTransitionError.confirmationTimedOut.localizedDescription)
    }

    @Test("rapid Next rejects overlap and evaluates the outgoing track once")
    func rapidNextRejectsOverlapAndEvaluatesOutgoingOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.blockNextCommand = true

        let first = Task { @MainActor in
            await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        }
        while fixture.player.nextCallCount == 0 {
            await Task.yield()
        }
        #expect(fixture.controller.isPlaybackTransitionInFlight)
        #expect(fixture.controller.remoteCommandAvailability == .unavailable)
        let second = Task { @MainActor in
            await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        }
        await second.value
        fixture.player.releaseBlockedNextCommand()
        await first.value

        #expect(fixture.player.nextCallCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("remote Next reports failure before scheduling when settings cannot load")
    func remoteNextReportsSynchronousSettingsFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let service = RemoteCommandService()

        let status = service.handleNextCommand(
            playbackController: fixture.controller,
            context: fixture.context,
            settingsProvider: { _ in throw ReconciliationTestFailure.expected }
        )
        await Task.yield()

        #expect(status == .commandFailed)
        #expect(fixture.player.nextCallCount == 0)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
    }

    @Test("failed Previous does not poison a later countable transition")
    func failedPreviousDoesNotPoisonLaterTransition() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 1)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.previousFailuresRemaining = 1

        await fixture.controller.previous(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[1].skipCount == 0)

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        #expect(fixture.items[1].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("playlist replacement failure restores prior correlation before a later success")
    func playlistReplacementFailureRestoresPriorCorrelationBeforeSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let target = try fixture.addPlaylist(prefix: "replacement", trackCount: 2)
        fixture.player.playFailuresRemaining = 1

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == target.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == target.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("failed queue restoration clears stale playback identity")
    func failedQueueRestorationClearsStalePlaybackIdentity() async throws {
        let fixture = try makeFixture(maximumObservationCount: 3)
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let target = try fixture.addPlaylist(prefix: "unrestorable", trackCount: 2)
        fixture.player.playFailuresRemaining = 1
        fixture.player.replacementConfirmationDelays = [0, 100]
        fixture.player.clearCurrentEntryWhileReplacementPending = true

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.currentTrack == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
        #expect(LocalPlaybackStateStore.load() == nil)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("shuffle and repeat restart evaluate outgoing tracks only after confirmation")
    func shuffleAndRepeatRestartEvaluateOutgoingAfterConfirmation() async throws {
        let shuffle = try makeFixture()
        defer { shuffle.cleanUp() }
        try await shuffle.start(at: 0)
        shuffle.player.playbackTime = 15
        await shuffle.controller.reconcilePlayerState(context: shuffle.context)
        let outgoingID = shuffle.controller.currentTrack?.id

        await shuffle.controller.reshuffleCurrentPlaylist(context: shuffle.context)

        let shuffledOrder = PlaybackOrderStore.state(
            playerID: shuffle.playerID,
            musicPlaylistID: shuffle.playlist.musicPlaylistID
        ).orderedTrackIDs
        #expect(shuffle.controller.currentTrack?.id != outgoingID)
        #expect(shuffle.controller.activePlaylistSnapshot?.rows.map(\.localTrackID) == shuffledOrder)
        #expect(shuffle.items[0].skipCount == 1)
        #expect(try shuffle.history().count == 1)

        let repeatFixture = try makeFixture()
        defer { repeatFixture.cleanUp() }
        try await repeatFixture.start(at: 2)
        repeatFixture.player.playbackTime = 179
        await repeatFixture.controller.reconcilePlayerState(context: repeatFixture.context)
        repeatFixture.player.finishQueueNaturally()

        await repeatFixture.controller.reconcilePlayerState(context: repeatFixture.context)

        let repeatedOrder = PlaybackOrderStore.state(
            playerID: repeatFixture.playerID,
            musicPlaylistID: repeatFixture.playlist.musicPlaylistID
        ).orderedTrackIDs
        #expect(repeatFixture.controller.currentTrack?.id != repeatFixture.musicTracks[2].id.rawValue)
        #expect(repeatFixture.controller.activePlaylistSnapshot?.rows.map(\.localTrackID) == repeatedOrder)
        #expect(repeatFixture.items[2].playthroughCount == 1)
        #expect(repeatFixture.items[2].skipCount == 0)
        #expect(try repeatFixture.history().count == 1)
    }

    @Test("externally observed natural advance uses the same reconciliation path")
    func externallyObservedNaturalAdvanceUsesSharedReconciliation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 179
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.advanceExternally()

        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().count == 1)
    }

    @Test("recovered current playthrough immediately republishes controller metadata")
    func recoveredCurrentPlaythroughRepublishesControllerMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let previousMetadataVersion = fixture.controller.playbackItemMetadataVersion
        fixture.player.playbackTime = 180
        let reconciliationContext = ModelContext(fixture.container)

        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: reconciliationContext,
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let verificationContext = ModelContext(fixture.container)
        let persistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: verificationContext
        ))

        #expect(result.countedLocalTrackIDs == [fixture.tracks[0].id.uuidString])
        #expect(persistedItem.playthroughCount == 1)
        #expect(fixture.controller.currentTrack?.playthroughCount == 1)
        #expect(fixture.controller.displayedPlaythroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[0].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(try verificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 1)
    }

    @Test("failed recovered playthrough save publishes nothing and remains retryable")
    func failedRecoveredPlaythroughSavePublishesNothingAndRemainsRetryable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 180
        PlaybackWaypointStore.clear(flushImmediately: true)

        let failedResult = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: ModelContext(fixture.container),
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher(),
            saveChanges: { _ in throw ReconciliationTestFailure.expected }
        )
        let failedVerificationContext = ModelContext(fixture.container)
        let unchangedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: failedVerificationContext
        ))

        #expect(failedResult.countedLocalTrackIDs.isEmpty)
        #expect(unchangedItem.playthroughCount == 0)
        #expect(try failedVerificationContext.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
        #expect(PlaybackWaypointStore.load() == nil)
        #expect(fixture.controller.currentTrack?.playthroughCount == 0)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first?.playthroughCount == 0)

        let retryResult = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: ModelContext(fixture.container),
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let retryVerificationContext = ModelContext(fixture.container)
        let persistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: retryVerificationContext
        ))

        #expect(retryResult.countedLocalTrackIDs == [fixture.tracks[0].id.uuidString])
        #expect(persistedItem.playthroughCount == 1)
        #expect(try retryVerificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 1)
        #expect(fixture.controller.currentTrack?.playthroughCount == 1)
    }

    @Test("recovered non-current playthroughs patch the active projection after player reconciliation")
    func recoveredNonCurrentPlaythroughsPatchActiveProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 170
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        PlaybackWaypointStore.save(
            PlaybackWaypoint(
                playlistID: fixture.playlist.musicPlaylistID,
                localTrackID: fixture.tracks[0].id.uuidString,
                positionSeconds: 170,
                durationSeconds: 180,
                recordedAt: Date().addingTimeInterval(-200)
            ),
            flushImmediately: true
        )
        fixture.player.advanceExternally()
        fixture.player.advanceExternally()
        fixture.player.playbackTime = 10
        let reconciliationContext = ModelContext(fixture.container)

        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: reconciliationContext,
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let verificationContext = ModelContext(fixture.container)
        let firstPersistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: verificationContext
        ))
        let secondPersistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[1].id,
            in: verificationContext
        ))

        #expect(result.countedLocalTrackIDs == [
            fixture.tracks[0].id.uuidString,
            fixture.tracks[1].id.uuidString
        ])
        #expect(firstPersistedItem.playthroughCount == 1)
        #expect(secondPersistedItem.playthroughCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[0].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[1].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[2].id.uuidString
        }?.isCurrent == true)
        #expect(try verificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 2)
    }

    @Test("Next landing outside the realized queue clears stale playlist correlation")
    func nextOutsideQueueClearsStalePlaylistCorrelation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let external = try fixture.addPlaylist(prefix: "external", trackCount: 1)
        fixture.player.nextEntryOverride = MusicPlayer.Queue.Entry(external.musicTracks[0])

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == external.musicTracks[0].id.rawValue)
        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.nowPlayingDisplayLocalTrackID == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
        #expect(LocalPlaybackStateStore.load() == nil)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }
}

@MainActor
private final class TransitionSleepProbe {
    var observedTrackIDs: [String?] = []
    var observedRestoreTrackIDs: [String?] = []
    var observedCurrentRowTrackIDs: [String?] = []
    var handler: (() -> Void)?
}

@MainActor
private final class ControllablePlaybackPlayer: PlaybackPlayer {
    enum Failure: Error {
        case commandFailed
        case queueEnded
    }

    var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    var playbackTime: TimeInterval = 0
    var playFailuresRemaining = 0
    var nextFailuresRemaining = 0
    var previousFailuresRemaining = 0
    var nextConfirmationDelays: [Int] = []
    var previousConfirmationDelays: [Int] = []
    var replacementConfirmationDelays: [Int] = []
    var clearCurrentEntryWhileReplacementPending = false
    var nextEntryOverride: MusicPlayer.Queue.Entry?
    var suppressCurrentEntryReporting = false
    var nextRevealsUnchangedEntry = false
    var blockNextCommand = false
    private(set) var nextCallCount = 0

    private var entries: [MusicPlayer.Queue.Entry] = []
    private var currentEntryStorage: MusicPlayer.Queue.Entry?
    private var pendingTransition: (entry: MusicPlayer.Queue.Entry?, remainingReads: Int)?
    private var blockedNextContinuation: CheckedContinuation<Void, Never>?

    var currentEntry: MusicPlayer.Queue.Entry? {
        guard !suppressCurrentEntryReporting else { return nil }
        if let pendingTransition {
            if pendingTransition.remainingReads == 0 {
                currentEntryStorage = pendingTransition.entry
                self.pendingTransition = nil
            } else {
                self.pendingTransition?.remainingReads -= 1
            }
        }
        return currentEntryStorage
    }

    func replaceQueue(with materialization: PlaybackQueueMaterialization) {
        entries = materialization.queueEntries
        let target = materialization.startingEntry ?? materialization.queueEntries.first
        let delay = replacementConfirmationDelays.isEmpty ? 0 : replacementConfirmationDelays.removeFirst()
        if delay > 0, clearCurrentEntryWhileReplacementPending {
            currentEntryStorage = nil
        }
        scheduleTransition(to: target, afterReads: delay)
    }

    func prepareToPlay() async throws {}

    func play() async throws {
        if playFailuresRemaining > 0 {
            playFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        playbackStatus = .playing
    }

    func pause() {
        playbackStatus = .paused
    }

    func skipToNextEntry() async throws {
        nextCallCount += 1
        if blockNextCommand {
            await withCheckedContinuation { continuation in
                blockedNextContinuation = continuation
            }
            blockNextCommand = false
        }
        if nextFailuresRemaining > 0 {
            nextFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        if nextRevealsUnchangedEntry {
            nextRevealsUnchangedEntry = false
            suppressCurrentEntryReporting = false
            return
        }
        if let nextEntryOverride {
            self.nextEntryOverride = nil
            scheduleTransition(to: nextEntryOverride, afterReads: 0)
            return
        }
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index + 1) else {
            self.currentEntryStorage = nil
            playbackStatus = .stopped
            throw Failure.queueEnded
        }
        let delay = nextConfirmationDelays.isEmpty ? 0 : nextConfirmationDelays.removeFirst()
        scheduleTransition(to: entries[index + 1], afterReads: delay)
    }

    func skipToPreviousEntry() async throws {
        if previousFailuresRemaining > 0 {
            previousFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index - 1) else {
            throw Failure.commandFailed
        }
        let delay = previousConfirmationDelays.isEmpty ? 0 : previousConfirmationDelays.removeFirst()
        scheduleTransition(to: entries[index - 1], afterReads: delay)
    }

    func appendToQueue(_ tracks: [Track]) async throws {
        entries.append(contentsOf: tracks.map { MusicPlayer.Queue.Entry($0) })
    }

    func disablePlaybackModes() {}

    func releaseBlockedNextCommand() {
        blockedNextContinuation?.resume()
        blockedNextContinuation = nil
    }

    func advanceExternally() {
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index + 1) else { return }
        scheduleTransition(to: entries[index + 1], afterReads: 0)
        _ = currentEntry
        playbackTime = 0
    }

    func finishQueueNaturally() {
        currentEntryStorage = nil
        pendingTransition = nil
        playbackStatus = .stopped
    }

    private func scheduleTransition(to entry: MusicPlayer.Queue.Entry?, afterReads: Int) {
        if afterReads == 0 {
            currentEntryStorage = entry
            pendingTransition = nil
        } else {
            pendingTransition = (entry, afterReads)
        }
        playbackTime = 0
    }
}

@MainActor
private struct EmptyMusicLibraryPlaybackHistoryFetcher: MusicLibraryPlaybackHistoryFetching {
    func snapshots(
        for candidates: [MusicLibraryPlaybackCandidate]
    ) async throws -> [String: MusicLibraryPlaybackSnapshot] {
        _ = candidates
        return [:]
    }
}

private enum ReconciliationTestFailure: Error {
    case expected
}

@MainActor
private struct PlaybackTransitionFixture {
    struct AddedPlaylist {
        var playlist: PlaylistRecord
        var tracks: [TrackRecord]
        var items: [PlaylistItemRecord]
        var musicTracks: [Track]
    }

    var container: ModelContainer
    var context: ModelContext
    var playlist: PlaylistRecord
    var tracks: [TrackRecord]
    var items: [PlaylistItemRecord]
    var musicTracks: [Track]
    var settings: OverplaySettings
    var player: ControllablePlaybackPlayer
    var controller: PlaybackController
    var sleepProbe: TransitionSleepProbe
    var playerID: String

    func start(at index: Int) async throws {
        await controller.playPlaylist(
            playlist,
            startingAt: tracks[index],
            settings: settings,
            context: context
        )
        #expect(controller.currentTrack?.id == musicTracks[index].id.rawValue)
    }

    func history() throws -> [HistoryEvent] {
        try context.fetch(FetchDescriptor<HistoryEvent>())
    }

    func addPlaylist(prefix: String, trackCount: Int) throws -> AddedPlaylist {
        let added = try Self.insertPlaylist(prefix: prefix, trackCount: trackCount, context: context)
        try context.save()
        return added
    }

    func cleanUp() {
        PlaybackOrderStore.clear(
            playerID: playerID,
            musicPlaylistID: playlist.musicPlaylistID,
            flushImmediately: true
        )
        LocalPlaybackStateStore.clear(flushImmediately: true)
        PlaybackWaypointStore.clear(flushImmediately: true)
    }

    static func insertPlaylist(
        prefix: String,
        trackCount: Int,
        context: ModelContext
    ) throws -> AddedPlaylist {
        let playlist = PlaylistRecord(
            musicPlaylistID: "\(prefix)-playlist-\(UUID().uuidString)",
            name: prefix
        )
        context.insert(playlist)
        var tracks: [TrackRecord] = []
        var items: [PlaylistItemRecord] = []
        var musicTracks: [Track] = []
        for index in 0..<trackCount {
            let musicTrack = try makeMusicTrack(id: "\(prefix)-music-\(index)", title: "\(prefix) \(index)")
            let track = TrackRecord(
                catalogID: musicTrack.id.rawValue,
                libraryID: musicTrack.id.rawValue,
                title: musicTrack.title,
                artistName: musicTrack.artistName,
                durationSeconds: 180,
                musicKitPlaybackData: try JSONEncoder().encode(musicTrack),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            let item = PlaylistItemRecord(
                playlistID: playlist.id,
                trackID: track.id,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            context.insert(track)
            context.insert(item)
            tracks.append(track)
            items.append(item)
            musicTracks.append(musicTrack)
        }
        return AddedPlaylist(playlist: playlist, tracks: tracks, items: items, musicTracks: musicTracks)
    }

    private static func makeMusicTrack(id: String, title: String) throws -> Track {
        let data = """
        {
          "id": "\(id)",
          "type": "songs",
          "attributes": {
            "albumName": "Album",
            "artistName": "Artist",
            "durationInMillis": 180000,
            "genreNames": [],
            "name": "\(title)",
            "trackNumber": 1
          }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(Track.self, from: data)
    }
}

@MainActor
private func makeFixture(maximumObservationCount: Int = 5) throws -> PlaybackTransitionFixture {
    LocalPlaybackStateStore.clear(flushImmediately: true)
    let container = try OverplayTestSupport.makeModelContainer()
    let context = container.mainContext
    let added = try PlaybackTransitionFixture.insertPlaylist(prefix: "main", trackCount: 3, context: context)
    let settings = OverplaySettings(
        selectedPlaylistID: added.playlist.musicPlaylistID,
        selectedPlaylistName: added.playlist.name,
        skipThresholdPercentage: 50,
        minimumSkipListeningSeconds: 0,
        playthroughThresholdPercentage: 100
    )
    context.insert(settings)
    try context.save()

    let player = ControllablePlaybackPlayer()
    let sleepProbe = TransitionSleepProbe()
    let playerID = "transition-tests-\(UUID().uuidString)"
    let controller = PlaybackController(
        playerID: playerID,
        player: player,
        transitionConfirmationPolicy: PlaybackTransitionConfirmationPolicy(
            maximumObservationCount: maximumObservationCount,
            observationInterval: .zero
        ),
        sleepForTransitionConfirmation: { _ in
            sleepProbe.handler?()
            await Task.yield()
        }
    )
    return PlaybackTransitionFixture(
        container: container,
        context: context,
        playlist: added.playlist,
        tracks: added.tracks,
        items: added.items,
        musicTracks: added.musicTracks,
        settings: settings,
        player: player,
        controller: controller,
        sleepProbe: sleepProbe,
        playerID: playerID
    )
}
