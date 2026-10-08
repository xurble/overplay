#if targetEnvironment(simulator)
@preconcurrency import MusicKit
import Foundation
import OSLog

/// The simulator has no Apple Music library, so nothing can be prepared or
/// played there. This stands in for `ApplicationMusicPlaybackPlayer` in
/// simulator runs: it plays the queue on a clock, reports each song as
/// MusicKit would, and goes through the same controller paths, so the
/// player's layout, artwork and theme can be checked without Apple Music.
@MainActor
final class SimulatorPlaybackPlayer: PlaybackPlayer {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "SimulatorPlayback")

    private var entries: [PlayerEntrySnapshot] = []
    private var currentIndex: Int?
    private var entryCounter = 0
    private var elapsedBeforeRun: TimeInterval = 0
    private var runStartedAt: Date?
    private var ticker: Task<Void, Never>?
    private var observationHandler: (@MainActor (Set<PlaybackPlayerChange>) async -> Void)?

    private(set) var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    private(set) var reportedShuffleMode: MusicPlayer.ShuffleMode? = .off
    private(set) var reportedRepeatMode: MusicPlayer.RepeatMode? = MusicPlayer.RepeatMode.none

    var currentEntryID: String? { currentEntry?.entryID }
    var currentEntry: PlayerEntrySnapshot? {
        currentIndex.flatMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    var queueEntries: [PlayerEntrySnapshot] { entries }
    var loadedEntryCount: Int { entries.count }

    var playbackTime: TimeInterval {
        get { elapsedBeforeRun + (runStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0) }
        set {
            elapsedBeforeRun = newValue
            if runStartedAt != nil { runStartedAt = .now }
        }
    }

    func setShuffleMode(_ mode: MusicPlayer.ShuffleMode) {
        reportedShuffleMode = mode
        if mode == .songs, let currentIndex, currentIndex + 1 < entries.count {
            entries = Array(entries[...currentIndex]) + entries[(currentIndex + 1)...].shuffled()
        }
        notify()
    }

    func setRepeatMode(_ mode: MusicPlayer.RepeatMode) {
        reportedRepeatMode = mode
        notify()
    }

    func submitQueue(_ tracks: [Track], startingAt index: Int) {
        entries = tracks.map { track in
            entryCounter += 1
            let item: PlayerItemSnapshot? = switch track {
            case .song(let song): ApplicationMusicPlaybackPlayer.snapshot(of: .song(song))
            case .musicVideo(let video): ApplicationMusicPlaybackPlayer.snapshot(of: .musicVideo(video))
            @unknown default: nil
            }
            return PlayerEntrySnapshot(entryID: "simulator-\(entryCounter)", item: item)
        }
        currentIndex = entries.isEmpty ? nil : min(max(index, 0), entries.count - 1)
        restartClock(playing: false)
        playbackStatus = .paused
        Self.logger.info("Queue: \(self.entries.count, privacy: .public) songs from \(index, privacy: .public)")
        notify()
    }

    func prepareToPlay() async throws {}

    func play() async throws {
        guard currentIndex != nil else { return }
        playbackStatus = .playing
        restartClock(playing: true)
        Self.logger.info("Play: \(self.currentEntry?.item?.title ?? "nil", privacy: .public)")
        notify()
    }

    func pause() {
        guard playbackStatus == .playing else { return }
        elapsedBeforeRun = playbackTime
        runStartedAt = nil
        ticker?.cancel()
        playbackStatus = .paused
        notify()
    }

    func skipToNextEntry() async throws { advance(by: 1) }

    func skipToPreviousEntry() async throws { advance(by: -1) }

    func selectEntry(withID entryID: String) throws {
        guard let index = entries.firstIndex(where: { $0.entryID == entryID }) else {
            throw PlaybackQueueEntryError.entryNotInQueue
        }
        currentIndex = index
        restartClock(playing: playbackStatus == .playing)
        notify()
    }

    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void) {
        observationHandler = handler
    }

    func refreshObservationBindings() {}

    func stopObservingChanges() {
        observationHandler = nil
    }

    // MARK: - Clock

    private func advance(by step: Int) {
        guard let currentIndex else { return }
        let next = currentIndex + step
        if entries.indices.contains(next) {
            self.currentIndex = next
        } else if step > 0, reportedRepeatMode == .all, !entries.isEmpty {
            self.currentIndex = 0
        } else if step < 0 {
            self.currentIndex = 0
        } else {
            self.currentIndex = nil
            playbackStatus = .stopped
        }
        restartClock(playing: playbackStatus == .playing)
        notify()
    }

    private func restartClock(playing: Bool) {
        ticker?.cancel()
        elapsedBeforeRun = 0
        runStartedAt = playing ? .now : nil
        guard playing else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                let duration = self.currentEntry?.item?.durationSeconds ?? 180
                if self.playbackTime >= duration { self.advance(by: 1) }
            }
        }
    }

    private func notify() {
        guard let observationHandler else { return }
        Task { await observationHandler([.queue, .state]) }
    }

    // MARK: - Preparation

    /// Builds playable songs from the library records themselves, artwork
    /// link included, in place of Apple Music lookups.
    static func prepare(_ tracks: [TrackRecord], refreshing: Set<UUID>) async throws {
        for track in tracks where DevicePlaybackCache.shared.data(for: track.id) == nil || refreshing.contains(track.id) {
            let id = track.libraryID ?? track.catalogID ?? track.id.uuidString
            var attributes: [String: Any] = [
                "name": track.title,
                "artistName": track.artistName,
                "albumName": track.albumTitle ?? "",
                "genreNames": [String](),
                "durationInMillis": Int((track.durationSeconds ?? 180) * 1000),
                "playParams": ["id": id, "kind": "song", "isLibrary": track.libraryID != nil]
            ]
            if let template = track.artworkURLTemplate {
                attributes["artwork"] = ["url": template, "width": 1200, "height": 1200]
            }
            let json: [String: Any] = [
                "id": id,
                "type": track.libraryID != nil ? "library-songs" : "songs",
                "attributes": attributes
            ]
            let song = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: json))
            DevicePlaybackCache.shared.set(try JSONEncoder().encode(Track.song(song)), for: track.id)
        }
    }
}
#endif
