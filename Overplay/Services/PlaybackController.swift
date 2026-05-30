import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackController {
    var currentTrack: TrackedTrack?
    var currentPlaylistItem: PlaylistItemRecord?
    var elapsedSeconds: Double = 0
    var durationSeconds: Double?
    var isPlaying = false
    var currentPlaylistID: String?
    var statusMessage: String?

    @ObservationIgnored private let player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: TrackPlaySession?

    var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(elapsedSeconds / durationSeconds, 1)
    }

    var canControlPlayback: Bool {
        currentPlaylistID != nil && currentTrack != nil
    }

    var shuffleEnabled: Bool {
        player.state.shuffleMode == .songs
    }

    var repeatModeTitle: String {
        switch player.state.repeatMode {
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
            try TrackRepository.upsert(snapshot(from: track, playlistID: playlistID), in: context)
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

        player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: startingTrack)
        try await player.play()
        currentPlaylistID = playlistID
        statusMessage = nil
        await refresh(context: context)
    }

    private func refreshPlaylistInBackground(_ playlist: PlaylistRecord, context: ModelContext) {
        Task(priority: .background) {
            do {
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? context.save()
            }
        }
    }

    func togglePlayPause() async {
        do {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                try await player.play()
            }
            isPlaying = player.state.playbackStatus == .playing
        } catch {
            statusMessage = error.localizedDescription
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
    }

    func cycleRepeatMode() {
        switch player.state.repeatMode {
        case nil, .some(.none):
            player.state.repeatMode = .all
        case .some(.all):
            player.state.repeatMode = .one
        case .some(.one):
            player.state.repeatMode = MusicPlayer.RepeatMode.none
        @unknown default:
            player.state.repeatMode = MusicPlayer.RepeatMode.none
        }
    }

    func clearLocalStateAfterDatabaseReset() {
        player.pause()
        currentTrack = nil
        currentPlaylistItem = nil
        elapsedSeconds = 0
        durationSeconds = nil
        isPlaying = false
        currentPlaylistID = nil
        activeSession = nil
        statusMessage = "Overplay data reset."
        NowPlayingMetadataService.update(track: nil, elapsed: 0, isPlaying: false)
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

        guard let currentTrack else { return }
        EvictionEngine.keep(currentTrack, settings: settings, context: context)
        try? context.save()
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

        guard let currentTrack else { return }
        EvictionEngine.evict(currentTrack, reason: "Evicted manually", context: context)
        try? context.save()
        await removeEvictedTrackFromPlaylist(currentTrack, context: context)
        await next(settings: settings, context: context)
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
            durationSeconds: track.duration
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
            currentTrack = try? TrackRepository.track(id: newTrackID, in: context)
            if currentTrack == nil,
               let snapshot = snapshot(from: player.queue.currentEntry?.item, playlistID: currentPlaylistID ?? (try? SettingsRepository.settings(in: context).selectedPlaylistID)) {
                currentTrack = try? TrackRepository.upsert(snapshot, in: context)
                try? context.save()
            }
            currentPlaylistItem = try? playlistItem(matching: newTrackID, context: context)
            durationSeconds = currentTrack?.durationSeconds

            if activeSession?.trackID != newTrackID {
                activeSession = TrackPlaySession(
                    trackID: newTrackID,
                    sessionStartDate: .now,
                    lastObservedPlaybackTime: elapsedSeconds,
                    durationSeconds: durationSeconds,
                    hasEvaluated: false
                )
                EventRepository.log(trackID: newTrackID, eventType: "started", in: context)
                try? context.save()
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
        }

        NowPlayingMetadataService.update(track: currentTrack, elapsed: elapsedSeconds, isPlaying: isPlaying)
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

        guard let track = currentTrack, !track.isEvicted else { return }

        EvictionEngine.countPlaythrough(track, session: session, settings: settings, context: context)
        session.hasEvaluated = true
        activeSession = session
        try? context.save()
    }

    private func removeEvictedTrackFromPlaylist(_ track: TrackedTrack, context: ModelContext) async {
        guard track.isEvicted else { return }
        guard let playlistID = track.playlistID ?? (try? SettingsRepository.settings(in: context).selectedPlaylistID) else { return }

        do {
            try await PlaylistSyncService().removeTrackFromPlaylist(trackID: track.id, playlistID: playlistID)
            statusMessage = "Removed \(track.title) from the Apple Music playlist."
        } catch {
            statusMessage = "Evicted locally, but Apple Music playlist removal failed: \(error.localizedDescription)"
        }
    }

    private func removeEvictedItemFromPlaylist(_ item: PlaylistItemRecord, playlist: PlaylistRecord, context: ModelContext) async {
        guard item.evictedAt != nil else { return }
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

            let track = try TrackRepository.track(id: session.trackID, in: context)
            let wasEvicted = track?.isEvicted == true

            try EvictionEngine.evaluateSkip(
                session: session,
                transitionWasNaturalCompletion: naturalCompletion,
                settings: settings,
                context: context
            )
            session.hasEvaluated = true
            activeSession = session
            try context.save()

            if let track, !wasEvicted, track.isEvicted {
                await removeEvictedTrackFromPlaylist(track, context: context)
            }
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
}
