import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackController {
    var currentTrack: TrackedTrack?
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

        await playPlaylist(id: playlistID, context: context)
    }

    func playPlaylist(_ playlist: PlaylistRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(id: playlist.musicPlaylistID, context: context)
    }

    func playPlaylist(_ playlist: PlaylistRecord, startingAt track: TrackRecord, settings: OverplaySettings, context: ModelContext) async {
        await playPlaylist(id: playlist.musicPlaylistID, startingAt: track, context: context)
    }

    func isCurrentPlaylist(_ playlist: PlaylistRecord) -> Bool {
        currentPlaylistID == playlist.musicPlaylistID && currentTrack != nil
    }

    private func playPlaylist(id playlistID: String, context: ModelContext) async {
        await playPlaylist(id: playlistID, startingAt: nil, context: context)
    }

    private func playPlaylist(id playlistID: String, startingAt trackRecord: TrackRecord?, context: ModelContext) async {
        do {
            let tracks = try await PlaylistSyncService().playableMusicTracks(for: playlistID, in: context)
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
        } catch {
            statusMessage = error.localizedDescription
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

    func keepCurrent(settings: OverplaySettings, context: ModelContext) {
        guard let currentTrack else { return }
        EvictionEngine.keep(currentTrack, settings: settings, context: context)
        try? context.save()
    }

    func evictCurrent(settings: OverplaySettings, context: ModelContext) async {
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
               let snapshot = snapshot(from: player.queue.currentEntry?.item, playlistID: try? SettingsRepository.settings(in: context).selectedPlaylistID) {
                currentTrack = try? TrackRepository.upsert(snapshot, in: context)
                try? context.save()
            }
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

    private func evaluateActiveSession(settings: OverplaySettings, context: ModelContext, naturalCompletion: Bool) async {
        guard var session = activeSession else { return }
        session.lastObservedPlaybackTime = elapsedSeconds
        session.durationSeconds = durationSeconds
        do {
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
}
