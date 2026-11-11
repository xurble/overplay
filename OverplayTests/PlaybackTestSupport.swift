import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// An adversarial stand-in for MusicKit's player (spec: Acceptance gate).
///
/// It can re-issue entry IDs, report another identifier domain, hydrate late or
/// never, fail, block or ignore commands, change entries with no Overplay
/// command, report queue and state changes apart, and report a shuffled queue
/// order. A fake without these hides the failures that
/// matter on device.
@MainActor
final class FakePlaybackPlayer: PlaybackPlayer {
    enum Failure: Error { case commandFailed }

    private(set) var entries: [PlayerEntrySnapshot] = []
    private var hiddenItems: [String: PlayerItemSnapshot] = [:]
    private(set) var currentIndex: Int?
    private var entryCounter = 0

    var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    var playbackTime: TimeInterval = 0
    var reportedShuffleMode: MusicPlayer.ShuffleMode? = .off
    var reportedRepeatMode: MusicPlayer.RepeatMode? = MusicPlayer.RepeatMode.none

    /// Maps a submitted track ID to the ID the player reports for it.
    var reportedIDForSubmittedID: (String) -> String = { $0 }
    /// When false, submitted entries carry no item until `hydrateAll()`.
    var hydratesOnSubmit = true
    /// Replaces the starting entry's item on the next submission only.
    var nextSubmissionStartItem: PlayerItemSnapshot?
    var playFailuresRemaining = 0
    /// MusicKit reorders the upcoming entries when shuffle is enabled on a
    /// loaded queue; reversing them makes that order visible to tests.
    var reordersUpcomingOnShuffle = false
    /// Runs inside `prepareToPlay`, e.g. to report the interim entry (#76).
    var onPrepare: (@MainActor () async -> Void)?
    /// Runs inside `play`, e.g. to hang it (#84).
    var onPlay: (@MainActor () async -> Void)?
    /// Runs inside `skipToNextEntry`, e.g. to hang a skip-on-reach.
    var onNext: (@MainActor () async -> Void)?
    /// MusicKit loads a prepared queue over a fraction of a second, and
    /// shuffle then covers only the loaded entries (#76). When set, prepare
    /// loads this many and each read of `loadedEntryCount` loads this many
    /// more, until `stopsLoading`.
    var loadsEntriesInSteps: Int?
    var stopsLoading = false
    /// MusicKit reports the first entry as current, even playing, until it
    /// has loaded as far as the start entry (device probe, 2026-10-07).
    var reportsFirstEntryUntilLoaded = false
    private var loadedCount: Int?
    var prepareFailuresRemaining = 0
    var nextFailuresRemaining = 0
    var previousFailuresRemaining = 0
    /// Thrown by `selectEntry` for an entry the queue holds: a failure other
    /// than `entryNotInQueue`.
    var selectFailure: Error?
    /// `pause()` is heard but playback carries on (2026-10-19).
    var ignoresPause = false
    /// Shuffle and repeat writes are heard but the reported modes stay put.
    var ignoresModeWrites = false
    /// The next submissions do not take: the player keeps the queue it had.
    var submitFailuresRemaining = 0

    private(set) var commands: [String] = []
    private(set) var submittedTitles: [[String]] = []
    private(set) var submittedStartIndices: [Int] = []
    private var observationHandler: (@MainActor (Set<PlaybackPlayerChange>) async -> Void)?

    var submitCount: Int { submittedTitles.count }
    var playCount: Int { commands.filter { $0 == "play" }.count }

    var currentEntryID: String? { currentEntry?.entryID }

    var currentEntry: PlayerEntrySnapshot? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        if reportsFirstEntryUntilLoaded, let loaded = loadedCount, loaded <= currentIndex { return entries.first }
        return entries[currentIndex]
    }

    var queueEntries: [PlayerEntrySnapshot] { entries }

    var loadedEntryCount: Int {
        guard let step = loadsEntriesInSteps, let loaded = loadedCount else { return entries.count }
        if !stopsLoading { loadedCount = min(entries.count, loaded + step) }
        return loaded
    }

    func setShuffleMode(_ mode: MusicPlayer.ShuffleMode) {
        commands.append("shuffle=\(mode)")
        guard !ignoresModeWrites else { return }
        reportedShuffleMode = mode
        let loaded = min(loadedCount ?? entries.count, entries.count)
        if mode == .songs, reordersUpcomingOnShuffle, let currentIndex, currentIndex + 1 < loaded {
            entries = Array(entries[...currentIndex]) + entries[(currentIndex + 1)..<loaded].reversed() + entries[loaded...]
        }
    }

    func setRepeatMode(_ mode: MusicPlayer.RepeatMode) {
        commands.append("repeat=\(mode)")
        guard !ignoresModeWrites else { return }
        reportedRepeatMode = mode
    }

    func submitQueue(_ tracks: [Track], startingAt index: Int) {
        commands.append("submit")
        submittedTitles.append(tracks.map(\.title))
        submittedStartIndices.append(index)
        if submitFailuresRemaining > 0 {
            submitFailuresRemaining -= 1
            return
        }
        hiddenItems = [:]
        loadedCount = nil
        entries = tracks.map { track in
            entryCounter += 1
            let entryID = "entry-\(entryCounter)"
            let reportedID = reportedIDForSubmittedID(track.id.rawValue)
            let item = PlayerItemSnapshot(
                id: reportedID, identifiers: [reportedID], title: track.title, artistName: track.artistName,
                albumTitle: track.albumTitle, artworkURLTemplate: nil, durationSeconds: track.duration
            )
            if !hydratesOnSubmit { hiddenItems[entryID] = item }
            return PlayerEntrySnapshot(entryID: entryID, item: hydratesOnSubmit ? item : nil)
        }
        currentIndex = entries.isEmpty ? nil : min(max(index, 0), entries.count - 1)
        if let override = nextSubmissionStartItem, let currentIndex {
            entries[currentIndex].item = override
            nextSubmissionStartItem = nil
        }
        playbackTime = 0
    }

    func prepareToPlay() async throws {
        commands.append("prepare")
        loadedCount = loadsEntriesInSteps.map { min($0, entries.count) }
        if let onPrepare { await onPrepare() }
        if prepareFailuresRemaining > 0 {
            prepareFailuresRemaining -= 1
            throw Failure.commandFailed
        }
    }

    func play() async throws {
        commands.append("play")
        if let onPlay { await onPlay() }
        if playFailuresRemaining > 0 {
            playFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        if currentIndex != nil { playbackStatus = .playing }
    }

    func pause() {
        commands.append("pause")
        if !ignoresPause, playbackStatus == .playing { playbackStatus = .paused }
    }

    func skipToNextEntry() async throws {
        commands.append("next")
        if let onNext { await onNext() }
        if nextFailuresRemaining > 0 {
            nextFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        advance()
    }

    func skipToPreviousEntry() async throws {
        commands.append("previous")
        if previousFailuresRemaining > 0 {
            previousFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        guard let currentIndex else { return }
        self.currentIndex = max(currentIndex - 1, 0)
        playbackTime = 0
    }

    func selectEntry(withID entryID: String) throws {
        commands.append("select")
        guard let index = entries.firstIndex(where: { $0.entryID == entryID }) else {
            throw PlaybackQueueEntryError.entryNotInQueue
        }
        if let selectFailure { throw selectFailure }
        currentIndex = index
        playbackTime = 0
    }

    func startObservingChanges(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void) {
        observationHandler = handler
    }

    func refreshObservationBindings() {}
    func stopObservingChanges() { observationHandler = nil }

    // MARK: - Behaviour another surface or MusicKit itself causes

    /// The player moves on without Overplay: natural advance, Lock Screen,
    /// CarPlay transport or a headset.
    func externallyAdvance() async {
        advance()
        await notify()
    }

    /// The player moves on while Overplay is suspended and hears nothing.
    func silentlyAdvance(to position: Double) {
        advance()
        playbackTime = position
    }

    func externallySelect(index: Int) async {
        currentIndex = index
        playbackTime = 0
        await notify()
    }

    /// MusicKit re-materializes the queue with new entry IDs, optionally
    /// before the new entries' items have hydrated. Position is unchanged.
    func reissueEntryIDs(droppingItems: Bool = false) {
        entries = entries.map { entry in
            entryCounter += 1
            let entryID = "entry-\(entryCounter)"
            if droppingItems, let item = entry.item { hiddenItems[entryID] = item }
            return PlayerEntrySnapshot(entryID: entryID, item: droppingItems ? nil : entry.item)
        }
    }

    /// The current entry loses its item, as after a relaunch before hydration.
    func dehydrateCurrent() {
        guard let currentIndex, let item = entries[currentIndex].item else { return }
        hiddenItems[entries[currentIndex].entryID] = item
        entries[currentIndex].item = nil
    }

    /// The player abandons the queue mid-track, as on a delivery failure.
    func abandonQueue() async {
        currentIndex = nil
        playbackStatus = .stopped
        await notify()
    }

    func hydrateAll() {
        entries = entries.map { entry in
            PlayerEntrySnapshot(entryID: entry.entryID, item: entry.item ?? hiddenItems[entry.entryID])
        }
        hiddenItems = [:]
    }

    /// Replaces the current entry's item, e.g. a song Overplay never queued.
    func replaceCurrentItem(with item: PlayerItemSnapshot?) {
        guard let currentIndex else { return }
        entries[currentIndex].item = item
    }

    /// Changes another entry's item without telling anyone.
    func replaceItem(at index: Int, with item: PlayerItemSnapshot?) {
        entries[index].item = item
    }

    /// MusicKit reports queue and state changes separately as well as together.
    func notify(_ changes: Set<PlaybackPlayerChange> = [.queue, .state]) async {
        await observationHandler?(changes)
    }

    private func advance() {
        guard let currentIndex else { return }
        if currentIndex + 1 < entries.count {
            self.currentIndex = currentIndex + 1
        } else if reportedRepeatMode == .all, !entries.isEmpty {
            self.currentIndex = 0
        } else {
            self.currentIndex = nil
            playbackStatus = .stopped
        }
        playbackTime = 0
    }
}

/// A store, a playlist of tracks with cached native playback data, and a
/// controller driven by `FakePlaybackPlayer`.
@MainActor
struct PlaybackFixture {
    let container: ModelContainer
    let context: ModelContext
    let settings: OverplaySettings
    let playlist: PlaylistRecord
    let tracks: [TrackRecord]
    let items: [PlaylistItemRecord]
    let player: FakePlaybackPlayer
    let intentStore: PlaybackIntentStore
    let controller: PlaybackController
    private let suiteName: String

    /// Detached playback work (a skip on reach, a queue repair) can finish
    /// after its test has returned. Releasing a container resets its main
    /// context, and SwiftData traps on any later read of its models, so every
    /// fixture's store lives for the whole run, as the app's does.
    private static var retainedContainers: [ModelContainer] = []

    init(
        trackCount: Int = 3,
        role: PlaylistRole = .oneTruePlaylist,
        player: FakePlaybackPlayer = FakePlaybackPlayer(),
        intentStore: PlaybackIntentStore? = nil,
        container: ModelContainer? = nil,
        preparePlaybackTracks: @escaping @MainActor ([TrackRecord], Set<UUID>) async throws -> Void = { _, _ in },
        refreshUnknownApplePlayCount: @escaping @MainActor (UUID, ModelContext) async -> Int = { _, _ in 0 }
    ) throws {
        let container = try container ?? OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try OverplayTestSupport.seedSettings(in: context)
        let playlist: PlaylistRecord
        var tracks: [TrackRecord] = []
        var items: [PlaylistItemRecord] = []
        if let existing = try PlaylistRepository.playlist(musicPlaylistID: "playlist-main", in: context) {
            playlist = existing
            items = try PlaylistItemRepository.items(forPlaylistID: existing.id, in: context)
            tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        } else {
            playlist = role == .triageBucket
                ? try PlaylistRepository.triageBucket(in: context)
                : PlaylistRecord(musicPlaylistID: "playlist-main", name: "Main", role: role)
            if role != .triageBucket { context.insert(playlist) }
            for index in 0..<trackCount {
                let track = TrackRecord(catalogID: "cat-\(index)", libraryID: "i.lib-\(index)",
                                        title: "Song \(index)", artistName: "Artist \(index)", durationSeconds: 180)
                context.insert(track)
                // Newest first: the earliest index is displayed and queued first.
                let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id,
                                              createdAt: Date(timeIntervalSince1970: 1_000_000 - Double(index)))
                context.insert(item)
                DevicePlaybackCache.shared.set(try Self.encodedTrack(id: "i.lib-\(index)", title: "Song \(index)",
                                                                     artist: "Artist \(index)"), for: track.id)
                tracks.append(track)
                items.append(item)
            }
            try context.save()
        }
        let suiteName = "OverplayTests.Intent.\(UUID().uuidString)"
        let store = intentStore ?? PlaybackIntentStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).json"),
            defaults: UserDefaults(suiteName: suiteName)!
        )
        Self.retainedContainers.append(container)
        self.container = container
        self.context = context
        self.settings = settings
        self.playlist = playlist
        self.tracks = tracks.sorted { $0.title < $1.title }
        self.items = items
        self.player = player
        self.intentStore = store
        self.suiteName = suiteName
        controller = PlaybackController(
            player: player, intentStore: store, preparePlaybackTracks: preparePlaybackTracks,
            refreshUnknownApplePlayCount: refreshUnknownApplePlayCount, sleep: PlaybackFixture.manualSampling
        )
        // No backing files: fixture runs never touch the device's playback
        // cache directory or activity log. The playlist path reads
        // `DevicePlaybackCache.shared`, which is memory only under test.
        controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        controller.activityLog = MusicKitActivityLog(fileURL: nil)
        controller.startMonitoring(context: context)
    }

    /// Tests drive sampling with `samplePlayback()`. The controller's own loop
    /// sleeps (cancellably) instead of spinning on the main actor.
    static let manualSampling: @MainActor (Duration) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(3600))
    }

    func cleanUp() {
        controller.stopMonitoring()
        intentStore.clear()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func item(_ index: Int) throws -> PlaylistItemRecord {
        try #require(try PlaylistItemRepository.item(trackID: tracks[index].id, in: context))
    }

    /// Plays the current entry for `seconds`, one sample per second, as the
    /// monitor would.
    func listen(seconds: Int) async {
        for _ in 0..<seconds {
            player.playbackTime += 1
            await controller.samplePlayback()
        }
    }

    func listen(to position: Double) async {
        player.playbackTime = position - 1
        await controller.samplePlayback()
        player.playbackTime = position
        await controller.samplePlayback()
    }

    static func encodedTrack(id: String, title: String, artist: String, durationMillis: Int = 180_000) throws -> Data {
        let json = """
        {"id": "\(id)", "type": "songs", "attributes": {"albumName": "Album", "artistName": "\(artist)",
          "durationInMillis": \(durationMillis), "genreNames": [], "name": "\(title)", "trackNumber": 1}}
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        return try JSONEncoder().encode(track)
    }
}
