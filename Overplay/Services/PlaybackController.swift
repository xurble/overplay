import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackController {
    var currentTrack: CurrentPlaybackTrack?
    var currentPlaylistItem: PlaylistItemRecord?
    var elapsedSeconds: Double = 0
    var durationSeconds: Double?
    var isPlaying = false
    var currentPlaylistID: String?
    var statusMessage: String?
    private var playbackModeVersion = 0

    @ObservationIgnored private lazy var player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var warmUpTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundSyncTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeSession: TrackPlaySession?
    @ObservationIgnored private var hasRestoredLocalPlaybackState = false
    @ObservationIgnored private var prefetchedArtworkTrackID: String?

    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }

    var canControlPlayback: Bool {
        currentPlaylistID != nil && currentTrack != nil
    }

    var shuffleEnabled: Bool {
        _ = playbackModeVersion
        return player.state.shuffleMode == .songs
    }

    var repeatMode: MusicPlayer.RepeatMode {
        _ = playbackModeVersion
        return player.state.repeatMode ?? .none
    }

    var repeatEnabled: Bool {
        repeatMode != .none
    }

    var repeatsSingleTrack: Bool {
        repeatMode == .one
    }

    var repeatModeTitle: String {
        switch repeatMode {
        case .one:
            "1"
        case .all:
            "All"
        default:
            "Off"
        }
    }

    func startMonitoring(context: ModelContext) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refresh(context: context)
            }
        }
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
        backgroundSyncTasks.values.forEach { $0.cancel() }
        backgroundSyncTasks.removeAll()
        player.pause()
        currentTrack = nil
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        currentPlaylistID = nil
        activeSession = nil
        prefetchedArtworkTrackID = nil
        statusMessage = "Overplay data reset."
        hasRestoredLocalPlaybackState = false
        LocalPlaybackStateStore.clear()
        NowPlayingMetadataService.update(track: nil, elapsed: 0, isPlaying: false)
    }

    func restoreLocalPlaybackState(context: ModelContext) async {
        guard !hasRestoredLocalPlaybackState else { return }
        hasRestoredLocalPlaybackState = true

        guard let state = LocalPlaybackStateStore.load() else {
            return
        }

        do {
            guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: state.playlistID, in: context) else {
                return
            }

            let tracks = try await playableTracksForRestoration(playlist, context: context)
            guard let startingTrack = tracks.first(where: { $0.id.rawValue == state.musicItemID }) else {
                return
            }

            warmUpTask?.cancel()
            warmUpTask = nil

            currentPlaylistID = state.playlistID
            elapsedSeconds = state.elapsedSeconds
            isPlaying = false
            currentPlaylistItem = try playlistItem(matching: state.musicItemID, context: context)
            currentTrack = currentPlaybackTrack(
                musicItemID: state.musicItemID,
                playlistItem: currentPlaylistItem,
                context: context
            )
            durationSeconds = currentTrack?.durationSeconds
            statusMessage = nil
            player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startingTrack)
            player.playbackTime = state.elapsedSeconds
            player.pause()
            NowPlayingMetadataService.update(track: currentTrack, elapsed: elapsedSeconds, isPlaying: false)
            prefetchCurrentArtworkIfNeeded(musicItemID: state.musicItemID, playlistID: state.playlistID)
        } catch {
            statusMessage = "Could not restore playback: \(error.localizedDescription)"
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
            await playPlaylist(id: playlistID, context: context)
        }
    }

    func playPlaylist(_ playlist: PlaylistRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(playlist, startingAt: nil, context: context)
    }

    func playPlaylist(_ playlist: PlaylistRecord, startingAt track: TrackRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(playlist, startingAt: track, context: context)
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    private func playPlaylist(id playlistID: String, context: ModelContext) async {
        if let playlist = try? PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) {
            await playPlaylist(playlist, startingAt: nil, context: context)
            return
        }

        await playPlaylist(id: playlistID, startingAt: nil, context: context)
    }

    private func playPlaylist(_ playlist: PlaylistRecord, startingAt trackRecord: TrackRecord?, context: ModelContext) async {
        do {
            let cachedTracks = try cachedPlayableMusicTracks(for: playlist, in: context)
            if !cachedTracks.isEmpty {
                try await startPlayback(
                    tracks: cachedTracks,
                    playlistID: playlist.musicPlaylistID,
                    startingAt: trackRecord,
                    context: context
                )
                refreshPlaylistInBackground(playlist, context: context)
                return
            }

            let tracks = try await PlaylistSyncService().playableMusicTracks(for: playlist, in: context)
            try await startPlayback(
                tracks: tracks,
                playlistID: playlist.musicPlaylistID,
                startingAt: trackRecord,
                context: context
            )
            refreshPlaylistInBackground(playlist, context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func playPlaylist(id playlistID: String, startingAt trackRecord: TrackRecord?, context: ModelContext) async {
        do {
            let tracks = try await PlaylistSyncService().playableMusicTracks(for: playlistID, in: context)
            try await startPlayback(
                tracks: tracks,
                playlistID: playlistID,
                startingAt: trackRecord,
                context: context
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func cachedPlayableMusicTracks(for playlist: PlaylistRecord, in context: ModelContext) throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracksByID = Dictionary(uniqueKeysWithValues: try TrackRecordRepository.allTracks(in: context).map { ($0.id, $0) })
        return PlaybackQueueBuilder.cachedPlayableMusicTracks(items: items, tracksByID: tracksByID)
    }

    private func playableTracksForRestoration(_ playlist: PlaylistRecord, context: ModelContext) async throws -> [Track] {
        let cachedTracks = try cachedPlayableMusicTracks(for: playlist, in: context)
        if !cachedTracks.isEmpty {
            return cachedTracks
        }

        return try await PlaylistSyncService().playableMusicTracks(for: playlist, in: context)
    }

    private func startPlayback(
        tracks: [Track],
        playlistID: String,
        startingAt trackRecord: TrackRecord?,
        context: ModelContext
    ) async throws {
        guard !tracks.isEmpty else {
            statusMessage = "No playable tracks remain after local evictions."
            return
        }

        for track in tracks {
            try TrackRecordRepository.upsert(snapshot(from: track, playlistID: playlistID), in: context)
        }
        try context.save()

        let startingTrack = trackRecord.flatMap { record in
            tracks.first { track in
                track.id.rawValue == record.catalogID || track.id.rawValue == record.libraryID
            }
        }

        if trackRecord != nil && startingTrack == nil {
            statusMessage = "That track is not playable in this playlist."
            return
        }

        warmUpTask?.cancel()
        warmUpTask = nil

        player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startingTrack)
        try await player.play()
        currentPlaylistID = playlistID
        await ArtworkCacheService.shared.touchPlaylistUsage(playlistID)
        statusMessage = nil
        startMonitoring(context: context)
        await refresh(context: context)
    }

    private func refreshPlaylistInBackground(_ playlist: PlaylistRecord, context: ModelContext) {
        guard !isRunningTests else { return }

        let playlistID = playlist.id

        backgroundSyncTasks[playlistID]?.cancel()
        backgroundSyncTasks[playlistID] = Task(priority: .background) { @MainActor [weak self] in
            defer {
                self?.backgroundSyncTasks[playlistID] = nil
            }

            guard !Task.isCancelled else { return }

            do {
                guard let playlist = try PlaylistRepository.playlist(id: playlistID, in: context) else {
                    return
                }
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
            } catch {
                guard !Task.isCancelled else { return }

                if let playlist = try? PlaylistRepository.playlist(id: playlistID, in: context) {
                    playlist.lastSyncError = error.localizedDescription
                    playlist.updatedAt = .now
                    try? context.save()
                }
            }
        }
    }

    func togglePlayPause(context: ModelContext) async {
        do {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                try await player.play()
                startMonitoring(context: context)
            }
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func play(context: ModelContext) async {
        do {
            try await player.play()
            startMonitoring(context: context)
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        if let musicItemID = currentTrack?.id {
            persistLocalPlaybackState(musicItemID: musicItemID)
        }
    }

    func next(settings: OverplaySettings, context: ModelContext) async {
        await evaluateActiveSession(settings: settings, context: context, naturalCompletion: false)
        do {
            try await player.skipToNextEntry()
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func previous(context: ModelContext) async {
        do {
            try await player.skipToPreviousEntry()
            await refresh(context: context)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleShuffle() {
        player.state.shuffleMode = shuffleEnabled ? .off : .songs
        playbackModeVersion += 1
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .none:
            setRepeatMode(.all)
        case .all:
            setRepeatMode(.one)
        case .one:
            setRepeatMode(.none)
        @unknown default:
            setRepeatMode(.none)
        }
    }

    func setRepeatMode(_ repeatMode: MusicPlayer.RepeatMode) {
        player.state.repeatMode = repeatMode
        playbackModeVersion += 1
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func keepCurrent(settings: OverplaySettings, context: ModelContext) {
        if let item = currentPlaylistItem,
           let playlist = try? currentPlaylist(in: context) {
            item.skipCount = 0
            if settings.protectKeptTracks {
                item.protected = true
            }
            item.updatedAt = .now
            EventRepository.logHistory(
                playlistID: playlist.id,
                trackID: item.trackID,
                eventType: .skipIgnored,
                source: .user,
                skipCountAtEvent: item.skipCount,
                message: "Kept by user",
                in: context
            )
            try? context.save()
            return
        }

        statusMessage = "Choose a linked playlist track to keep."
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
        if let item = currentPlaylistItem,
           let playlist = try? currentPlaylist(in: context) {
            EvictionEngine.evict(
                item,
                playlist: playlist,
                reason: .manual,
                source: .user,
                message: "Evicted manually",
                context: context
            )
            try? context.save()
            await removeEvictedItemFromPlaylist(item, playlist: playlist, context: context)
            await next(settings: settings, context: context)
            return
        }

        statusMessage = "Choose a linked playlist track to evict."
    }

    private func snapshot(from track: Track, playlistID: String?) -> TrackSnapshot {
        TrackSnapshot(
            id: track.id.rawValue,
            catalogID: track.id.rawValue,
            libraryID: track.id.rawValue,
            playlistEntryID: nil,
            playlistID: playlistID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track)
        )
    }

    private func snapshot(from item: MusicPlayer.Queue.Entry.Item?, playlistID: String?) -> TrackSnapshot? {
        guard let item else { return nil }

        switch item {
        case let .song(song):
            return TrackSnapshot(
                id: song.id.rawValue,
                catalogID: song.id.rawValue,
                libraryID: song.id.rawValue,
                playlistEntryID: nil,
                playlistID: playlistID,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                artworkURLTemplate: song.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: song.duration
            )
        case let .musicVideo(musicVideo):
            return TrackSnapshot(
                id: musicVideo.id.rawValue,
                catalogID: musicVideo.id.rawValue,
                libraryID: musicVideo.id.rawValue,
                playlistEntryID: nil,
                playlistID: playlistID,
                title: musicVideo.title,
                artistName: musicVideo.artistName,
                albumTitle: nil,
                artworkURLTemplate: musicVideo.artwork?.url(width: 512, height: 512)?.absoluteString,
                durationSeconds: musicVideo.duration
            )
        @unknown default:
            return nil
        }
    }

    private func refresh(context: ModelContext) async {
        let oldTrackID = activeSession?.trackID
        let newTrackID = player.queue.currentEntry?.item?.id.rawValue
        elapsedSeconds = player.playbackTime
        isPlaying = player.state.playbackStatus == .playing

        if oldTrackID != nil, oldTrackID != newTrackID, let settings = try? SettingsRepository.settings(in: context) {
            await evaluateActiveSession(settings: settings, context: context, naturalCompletion: false)
        }

        if let newTrackID {
            currentPlaylistItem = try? playlistItem(matching: newTrackID, context: context)
            currentTrack = currentPlaybackTrack(
                musicItemID: newTrackID,
                playlistItem: currentPlaylistItem,
                context: context
            )
            durationSeconds = currentTrack?.durationSeconds
            prefetchCurrentArtworkIfNeeded(musicItemID: newTrackID, playlistID: currentPlaylistID)

            if activeSession?.trackID != newTrackID {
                activeSession = TrackPlaySession(
                    trackID: newTrackID,
                    sessionStartDate: .now,
                    lastObservedPlaybackTime: elapsedSeconds,
                    durationSeconds: durationSeconds,
                    hasEvaluated: false
                )
            } else {
                activeSession?.lastObservedPlaybackTime = elapsedSeconds
                activeSession?.durationSeconds = durationSeconds
            }

            evaluatePlaythroughIfNeeded(context: context)
        } else {
            currentTrack = nil
            currentPlaylistItem = nil
            durationSeconds = nil
            activeSession = nil
            currentPlaylistID = nil
            prefetchedArtworkTrackID = nil
        }

        NowPlayingMetadataService.update(track: currentTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)

        if let newTrackID {
            persistLocalPlaybackState(musicItemID: newTrackID)
        }
    }

    private func evaluatePlaythroughIfNeeded(context: ModelContext) {
        guard var session = activeSession, !session.hasEvaluated else { return }
        guard let settings = try? SettingsRepository.settings(in: context) else { return }
        guard let progress = session.progressPercentage else { return }
        guard progress >= settings.playthroughThresholdPercentage else { return }
        if let item = currentPlaylistItem,
           let playlist = try? currentPlaylist(in: context),
           item.evictedAt == nil {
            EvictionEngine.countPlaythrough(item, playlist: playlist, session: session, settings: settings, context: context)
            session.hasEvaluated = true
            activeSession = session
            try? context.save()
            return
        }

    }

    private func removeEvictedItemFromPlaylist(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async {
        guard item.evictedAt != nil else { return }
        guard playlist.allowsRemoteWrites else {
            statusMessage = "Evicted locally. \(playlist.name) is incoming only, so Apple Music was not changed."
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
            statusMessage = "Evicted locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
        }
    }

    private func evaluateActiveSession(settings: OverplaySettings, context: ModelContext, naturalCompletion: Bool) async {
        guard var session = activeSession else { return }
        session.lastObservedPlaybackTime = elapsedSeconds
        session.durationSeconds = durationSeconds
        do {
            if let item = currentPlaylistItem,
               let playlist = try currentPlaylist(in: context) {
                let wasEvicted = item.evictedAt != nil
                EvictionEngine.evaluateSkip(
                    item: item,
                    playlist: playlist,
                    session: session,
                    transitionWasNaturalCompletion: naturalCompletion,
                    settings: settings,
                    context: context
                )
                session.hasEvaluated = true
                activeSession = session
                try context.save()

                if !wasEvicted, item.evictedAt != nil {
                    await removeEvictedItemFromPlaylist(item, playlist: playlist, context: context)
                }
                return
            }

            session.hasEvaluated = true
            activeSession = session
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func currentPlaylist(in context: ModelContext) throws -> PlaylistRecord? {
        guard let currentPlaylistID else { return nil }
        return try PlaylistRepository.playlist(musicPlaylistID: currentPlaylistID, in: context)
    }

    private func playlistItem(matching musicItemID: String, context: ModelContext) throws -> PlaylistItemRecord? {
        guard let playlist = try currentPlaylist(in: context) else { return nil }
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracksByID = Dictionary(uniqueKeysWithValues: try TrackRecordRepository.allTracks(in: context).map { ($0.id, $0) })
        return PlaybackQueueBuilder.playlistItem(
            matching: musicItemID,
            items: items,
            tracksByID: tracksByID
        )
    }

    private func currentPlaybackTrack(
        musicItemID: String,
        playlistItem: PlaylistItemRecord?,
        context: ModelContext
    ) -> CurrentPlaybackTrack? {
        if let playlistItem,
           let trackRecord = try? TrackRecordRepository.track(id: playlistItem.trackID, in: context) {
            return CurrentPlaybackTrack(trackRecord, musicItemID: musicItemID, item: playlistItem)
        }

        if let trackRecord = try? TrackRecordRepository.track(musicItemID: musicItemID, in: context) {
            return CurrentPlaybackTrack(trackRecord, musicItemID: musicItemID, item: nil)
        }

        guard let snapshot = snapshot(from: player.queue.currentEntry?.item, playlistID: currentPlaylistID) else {
            return nil
        }

        return CurrentPlaybackTrack(snapshot)
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
        guard let currentPlaylistID else {
            return
        }

        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: currentPlaylistID,
            musicItemID: musicItemID,
            elapsedSeconds: elapsedSeconds,
            wasPlaying: isPlaying,
            updatedAt: .now
        ))
    }
}
