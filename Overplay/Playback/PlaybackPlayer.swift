import Combine
import Foundation
@preconcurrency import MusicKit

@MainActor
protocol PlaybackPlayer: AnyObject {
    var currentEntry: MusicPlayer.Queue.Entry? { get }
    /// The current entry's item can temporarily be unavailable while MusicKit
    /// hydrates an entry it has already made current.
    var currentEntryItem: MusicPlayer.Queue.Entry.Item? { get }
    var playbackStatus: MusicPlayer.PlaybackStatus { get }
    var playbackTime: TimeInterval { get set }
    /// The player's live queue, reduced to what Overplay needs to correlate
    /// entries it did not construct itself.
    var queueEntrySnapshots: [PlayerQueueEntrySnapshot] { get }
    /// MusicKit owns these now: Overplay reads them and writes what a surface
    /// asked for, rather than holding them off.
    var shuffleMode: MusicPlayer.ShuffleMode { get set }
    var repeatMode: MusicPlayer.RepeatMode { get set }
    /// Raw optional values reported by MusicKit. These remain separate from
    /// the effective modes so diagnostics can distinguish an explicit off
    /// state from MusicKit temporarily reporting no state at all.
    var reportedShuffleMode: MusicPlayer.ShuffleMode? { get }
    var reportedRepeatMode: MusicPlayer.RepeatMode? { get }

    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void)
    func refreshObservationBindings()
    func stopObservingChanges()

    func replaceQueue(with materialization: PlaybackQueueMaterialization)
    func prepareToPlay() async throws
    func play() async throws
    func pause()
    func skipToNextEntry() async throws
    func skipToPreviousEntry() async throws
    func skipToEntry(withID entryID: String) async throws
    func appendToQueue(_ tracks: [Track]) async throws
    func removeQueueEntries(withIDs entryIDs: Set<String>)
}

extension PlaybackPlayer {
    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void) {}
    func refreshObservationBindings() {}
    func stopObservingChanges() {}
    var reportedShuffleMode: MusicPlayer.ShuffleMode? { shuffleMode }
    var reportedRepeatMode: MusicPlayer.RepeatMode? { repeatMode }
}

@MainActor
final class ApplicationMusicPlaybackPlayer: PlaybackPlayer {
    private let player = ApplicationMusicPlayer.shared
    private lazy var observation = PlaybackPlayerObservation(
        queueSource: { [player] in
            let queue = player.queue
            return .init(identity: queue, changes: queue.objectWillChange.eraseToAnyPublisher())
        },
        stateChanges: player.state.objectWillChange.eraseToAnyPublisher()
    )

    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void) {
        observation.start(handler)
    }

    func refreshObservationBindings() { observation.rebindQueueIfNeeded() }
    func stopObservingChanges() { observation.stop() }

    var currentEntry: MusicPlayer.Queue.Entry? {
        player.queue.currentEntry
    }

    var currentEntryItem: MusicPlayer.Queue.Entry.Item? {
        player.queue.currentEntry?.item
    }

    var playbackStatus: MusicPlayer.PlaybackStatus {
        player.state.playbackStatus
    }

    var playbackTime: TimeInterval {
        get { player.playbackTime }
        set { player.playbackTime = newValue }
    }

    var queueEntrySnapshots: [PlayerQueueEntrySnapshot] {
        player.queue.entries.map {
            PlayerQueueEntrySnapshot(id: $0.id, musicItemID: $0.item?.id.rawValue)
        }
    }

    func replaceQueue(with materialization: PlaybackQueueMaterialization) {
        MusicKitActivityLog.shared.measure(
            .queueReplace,
            magnitude: Double(materialization.queueEntries.count),
            detail: materialization.startingEntry == nil ? "no starting entry" : nil
        ) {
            player.queue = ApplicationMusicPlayer.Queue(
                materialization.queueEntries,
                startingAt: materialization.startingEntry
            )
            observation.rebindQueueIfNeeded()
        }
    }

    func prepareToPlay() async throws {
        try await MusicKitActivityLog.shared.measure(.playerPrepare) {
            try await player.prepareToPlay()
        }
    }

    func play() async throws {
        try await MusicKitActivityLog.shared.measure(.playerPlay) {
            try await player.play()
        }
    }

    func pause() {
        MusicKitActivityLog.shared.measure(.playerPause) {
            player.pause()
        }
    }

    func skipToNextEntry() async throws {
        try await MusicKitActivityLog.shared.measure(.playerSkipNext) {
            try await player.skipToNextEntry()
        }
    }

    func skipToPreviousEntry() async throws {
        try await MusicKitActivityLog.shared.measure(.playerSkipPrevious) {
            try await player.skipToPreviousEntry()
        }
    }

    /// Jumps inside the queue that is already loaded, so everything after the
    /// target entry survives. Rebuilding the queue would lose that order.
    func skipToEntry(withID entryID: String) async throws {
        try await MusicKitActivityLog.shared.measure(
            .playerSkipToEntry,
            magnitude: Double(player.queue.entries.count)
        ) {
            guard let entry = player.queue.entries.first(where: { $0.id == entryID }) else {
                throw PlaybackQueueEntryError.entryNotInQueue
            }

            player.queue.currentEntry = entry
            try await player.play()
        }
    }

    func appendToQueue(_ tracks: [Track]) async throws {
        try await MusicKitActivityLog.shared.measure(
            .queueAppend,
            magnitude: Double(tracks.count)
        ) {
            try await player.queue.insert(tracks, position: .tail)
        }
    }

    func removeQueueEntries(withIDs entryIDs: Set<String>) {
        player.queue.entries.removeAll { entryIDs.contains($0.id) }
    }

    /// Both accessors are optional on `MusicPlayer.State`; nil means MusicKit
    /// has not reported one yet, which reads as off rather than unknown
    /// because a surface has to show something.
    var shuffleMode: MusicPlayer.ShuffleMode {
        get { reportedShuffleMode ?? .off }
        set {
            guard player.state.shuffleMode != newValue else { return }
            MusicKitActivityLog.shared.measure(.playerModeReset, detail: "shuffle=\(newValue)") {
                player.state.shuffleMode = newValue
            }
        }
    }

    var repeatMode: MusicPlayer.RepeatMode {
        // Spelled out: a bare `.none` against an optional binds to
        // `Optional.none`, which is a different case entirely.
        get { reportedRepeatMode ?? MusicPlayer.RepeatMode.none }
        set {
            guard player.state.repeatMode != newValue else { return }
            MusicKitActivityLog.shared.measure(.playerModeReset, detail: "repeat=\(newValue)") {
                player.state.repeatMode = newValue
            }
        }
    }

    var reportedShuffleMode: MusicPlayer.ShuffleMode? {
        player.state.shuffleMode
    }

    var reportedRepeatMode: MusicPlayer.RepeatMode? {
        player.state.repeatMode
    }
}

enum PlaybackQueueEntryError: LocalizedError, Equatable {
    case entryNotInQueue

    var errorDescription: String? {
        switch self {
        case .entryNotInQueue:
            "That track is no longer in the Apple Music queue."
        }
    }
}

enum PlaybackTransitionConfirmation: Equatable {
    case waiting
    case confirmed(entryID: String)
    case diverged(entryID: String)
}

enum PlaybackTransitionError: LocalizedError, Equatable {
    case confirmationTimedOut
    case transitionInProgress

    var errorDescription: String? {
        switch self {
        case .confirmationTimedOut:
            "Apple Music did not confirm the playback transition in time."
        case .transitionInProgress:
            "Another playback transition is still being confirmed."
        }
    }
}

struct PlaybackTransitionConfirmationPolicy: Equatable, Sendable {
    static let standard = PlaybackTransitionConfirmationPolicy(
        maximumObservationCount: 21,
        observationInterval: .milliseconds(100)
    )

    var maximumObservationCount: Int
    var observationInterval: Duration

    func resolution(
        outgoingEntryID: String?,
        expectedEntryIDs: Set<String>?,
        observedEntryID: String?
    ) -> PlaybackTransitionConfirmation {
        guard let observedEntryID,
              observedEntryID != outgoingEntryID else {
            return .waiting
        }

        guard let expectedEntryIDs,
              !expectedEntryIDs.contains(observedEntryID) else {
            return .confirmed(entryID: observedEntryID)
        }

        return .diverged(entryID: observedEntryID)
    }
}
