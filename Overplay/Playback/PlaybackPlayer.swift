import Foundation
@preconcurrency import MusicKit

@MainActor
protocol PlaybackPlayer: AnyObject {
    var currentEntry: MusicPlayer.Queue.Entry? { get }
    var playbackStatus: MusicPlayer.PlaybackStatus { get }
    var playbackTime: TimeInterval { get set }

    func replaceQueue(with materialization: PlaybackQueueMaterialization)
    func prepareToPlay() async throws
    func play() async throws
    func pause()
    func skipToNextEntry() async throws
    func skipToPreviousEntry() async throws
    func appendToQueue(_ tracks: [Track]) async throws
    func disablePlaybackModes()
}

@MainActor
final class ApplicationMusicPlaybackPlayer: PlaybackPlayer {
    private let player = ApplicationMusicPlayer.shared

    var currentEntry: MusicPlayer.Queue.Entry? {
        player.queue.currentEntry
    }

    var playbackStatus: MusicPlayer.PlaybackStatus {
        player.state.playbackStatus
    }

    var playbackTime: TimeInterval {
        get { player.playbackTime }
        set { player.playbackTime = newValue }
    }

    func replaceQueue(with materialization: PlaybackQueueMaterialization) {
        player.queue = ApplicationMusicPlayer.Queue(
            materialization.queueEntries,
            startingAt: materialization.startingEntry
        )
    }

    func prepareToPlay() async throws {
        try await player.prepareToPlay()
    }

    func play() async throws {
        try await player.play()
    }

    func pause() {
        player.pause()
    }

    func skipToNextEntry() async throws {
        try await player.skipToNextEntry()
    }

    func skipToPreviousEntry() async throws {
        try await player.skipToPreviousEntry()
    }

    func appendToQueue(_ tracks: [Track]) async throws {
        try await player.queue.insert(tracks, position: .tail)
    }

    func disablePlaybackModes() {
        player.state.shuffleMode = .off
        player.state.repeatMode = .none
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
