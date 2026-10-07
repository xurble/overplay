import Combine
import Foundation
@preconcurrency import MusicKit

/// What the player reports for one queue entry's item. Identifiers include the
/// reported ID and any catalog/library IDs carried by its play parameters,
/// because MusicKit may report a different identifier domain than was queued.
struct PlayerItemSnapshot: Equatable, Sendable {
    var id: String
    var identifiers: Set<String>
    var title: String
    var artistName: String
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
}

/// One entry as the player reports it. `item` is nil until MusicKit hydrates it.
struct PlayerEntrySnapshot: Equatable, Sendable {
    var entryID: String
    var item: PlayerItemSnapshot?
}

/// The only boundary between Overplay and MusicKit playback. Every command is
/// one call; nothing here waits for confirmation (`PLAY-013`).
@MainActor
protocol PlaybackPlayer: AnyObject {
    /// Cheap enough for the one-second sample.
    var currentEntryID: String? { get }
    var currentEntry: PlayerEntrySnapshot? { get }
    /// Enumerates the whole queue. Only for selection and transition direction,
    /// never on the sampling path (`LOAD-001`).
    var queueEntries: [PlayerEntrySnapshot] { get }
    /// How many entries MusicKit has loaded. After `prepareToPlay` it fills
    /// in over a fraction of a second (2, then 70, then 96 on device), and
    /// shuffle covers only what is loaded (#76).
    var loadedEntryCount: Int { get }
    var playbackStatus: MusicPlayer.PlaybackStatus { get }
    var playbackTime: TimeInterval { get set }
    /// Raw reports: nil means MusicKit has not said, which is not "off".
    var reportedShuffleMode: MusicPlayer.ShuffleMode? { get }
    var reportedRepeatMode: MusicPlayer.RepeatMode? { get }

    func setShuffleMode(_ mode: MusicPlayer.ShuffleMode)
    func setRepeatMode(_ mode: MusicPlayer.RepeatMode)
    func submitQueue(_ tracks: [Track], startingAt index: Int)
    func prepareToPlay() async throws
    func play() async throws
    func pause()
    func skipToNextEntry() async throws
    func skipToPreviousEntry() async throws
    func selectEntry(withID entryID: String) throws

    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void)
    func refreshObservationBindings()
    func stopObservingChanges()
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

    var currentEntryID: String? { player.queue.currentEntry?.id }

    var currentEntry: PlayerEntrySnapshot? {
        player.queue.currentEntry.map(Self.snapshot(of:))
    }

    var queueEntries: [PlayerEntrySnapshot] {
        player.queue.entries.map(Self.snapshot(of:))
    }

    var loadedEntryCount: Int { player.queue.entries.count }

    var playbackStatus: MusicPlayer.PlaybackStatus { player.state.playbackStatus }

    var playbackTime: TimeInterval {
        get { player.playbackTime }
        set { player.playbackTime = newValue }
    }

    var reportedShuffleMode: MusicPlayer.ShuffleMode? { player.state.shuffleMode }
    var reportedRepeatMode: MusicPlayer.RepeatMode? { player.state.repeatMode }

    func setShuffleMode(_ mode: MusicPlayer.ShuffleMode) {
        MusicKitActivityLog.shared.measure(.playerModeReset, detail: "shuffle=\(mode)") {
            player.state.shuffleMode = mode
        }
    }

    func setRepeatMode(_ mode: MusicPlayer.RepeatMode) {
        MusicKitActivityLog.shared.measure(.playerModeReset, detail: "repeat=\(mode)") {
            player.state.repeatMode = mode
        }
    }

    func submitQueue(_ tracks: [Track], startingAt index: Int) {
        let entries = tracks.map { MusicPlayer.Queue.Entry($0) }
        let start = entries.indices.contains(index) ? entries[index] : entries.first
        MusicKitActivityLog.shared.measure(.queueReplace, magnitude: Double(entries.count)) {
            player.queue = ApplicationMusicPlayer.Queue(entries, startingAt: start)
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

    func selectEntry(withID entryID: String) throws {
        try MusicKitActivityLog.shared.measure(.playerSkipToEntry) {
            guard let entry = player.queue.entries.first(where: { $0.id == entryID }) else {
                throw PlaybackQueueEntryError.entryNotInQueue
            }
            player.queue.currentEntry = entry
        }
    }

    private static func snapshot(of entry: MusicPlayer.Queue.Entry) -> PlayerEntrySnapshot {
        PlayerEntrySnapshot(entryID: entry.id, item: entry.item.flatMap(snapshot(of:)))
    }

    static func snapshot(of item: MusicPlayer.Queue.Entry.Item) -> PlayerItemSnapshot? {
        switch item {
        case let .song(song):
            let identity = MusicTrackIdentity.ids(fromRawID: song.id.rawValue, playParameters: song.playParameters)
            return PlayerItemSnapshot(
                id: song.id.rawValue,
                identifiers: Set([song.id.rawValue, identity.catalogID, identity.libraryID].compactMap { $0 }),
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURLTemplate: song.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: song.duration
            )
        case let .musicVideo(video):
            let identity = MusicTrackIdentity.ids(fromRawID: video.id.rawValue, playParameters: video.playParameters)
            return PlayerItemSnapshot(
                id: video.id.rawValue,
                identifiers: Set([video.id.rawValue, identity.catalogID, identity.libraryID].compactMap { $0 }),
                title: video.title,
                artistName: video.artistName,
                albumTitle: nil,
                artworkURLTemplate: video.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: video.duration
            )
        @unknown default:
            return nil
        }
    }
}
