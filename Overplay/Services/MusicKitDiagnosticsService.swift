import Foundation
@preconcurrency import MusicKit
import SwiftData

@MainActor
struct MusicKitDiagnosticsService {
    func run(settings: OverplaySettings, context: ModelContext) async -> String {
        var report = MusicKitDiagnosticsReport()

        report.add("Timestamp", Date().formatted(date: .numeric, time: .standard))
        report.add("Bundle ID", Bundle.main.bundleIdentifier ?? "nil")
        report.add("App version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "nil")
        report.add("Music usage description", Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String ?? "missing")
#if targetEnvironment(simulator)
        report.add("Run destination", "Simulator")
#else
        report.add("Run destination", "Device or Mac runtime")
#endif
        report.add("Note", "The MusicKit App Service cannot be fully introspected at runtime; these probes test the observable MusicKit surfaces.")

        probeAuthorization(into: &report)
        await probeSubscription(into: &report)
        await probeLibraryPlaylists(into: &report)
        let cachedTracks = await probeSelectedPlaylist(settings: settings, context: context, into: &report)
        await probeApplicationMusicPlayer(into: &report)
        await probeCachedPlaybackQueue(cachedTracks: cachedTracks, into: &report)

        return report.text
    }

    private func probeAuthorization(into report: inout MusicKitDiagnosticsReport) {
        report.add("MusicAuthorization.currentStatus", authorizationStatusDescription(MusicAuthorization.currentStatus))
    }

    private func probeSubscription(into report: inout MusicKitDiagnosticsReport) async {
        do {
            let subscription = try await MusicSubscription.current
            report.add("MusicSubscription.current", "ok")
            report.add("canPlayCatalogContent", String(subscription.canPlayCatalogContent))
            report.add("hasCloudLibraryEnabled", String(subscription.hasCloudLibraryEnabled))
        } catch {
            report.add("MusicSubscription.current", "failed: \(diagnosticDescription(for: error))")
        }
    }

    private func probeLibraryPlaylists(into report: inout MusicKitDiagnosticsReport) async {
        do {
            let playlists = try await PlaylistSyncService().fetchLibraryPlaylists()
            report.add("MusicLibraryRequest<Playlist>", "ok: \(playlists.count) playlists")
            if let firstPlaylist = playlists.first {
                report.add("First library playlist", "\(firstPlaylist.name) [\(firstPlaylist.id)]")
            }
        } catch {
            report.add("MusicLibraryRequest<Playlist>", "failed: \(diagnosticDescription(for: error))")
        }
    }

    private func probeSelectedPlaylist(
        settings: OverplaySettings,
        context: ModelContext,
        into report: inout MusicKitDiagnosticsReport
    ) async -> [Track] {
        guard let selectedPlaylistID = settings.selectedPlaylistID else {
            report.add("Selected playlist", "none")
            return []
        }

        report.add("Selected playlist ID", selectedPlaylistID)
        report.add("Selected playlist name", settings.selectedPlaylistName ?? "nil")
        await probeStoredPlaylistIDAlignment(
            storedID: selectedPlaylistID,
            name: settings.selectedPlaylistName,
            into: &report
        )

        do {
            guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: selectedPlaylistID, in: context) else {
                report.add("Local selected playlist record", "missing")
                return []
            }

            let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
            let playableItems = items.filter(\.isPlayable)
            let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
            let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
            let cachedTracks = PlaybackQueueBuilder.cachedPlayableMusicTracks(items: items, tracksByID: tracksByID)

            report.add("Local selected playlist record", "ok: \(playlist.name), role=\(playlist.role.rawValue), writes=\(playlist.writePolicy.rawValue)")
            report.add("Local playlist items", "\(items.count) total, \(playableItems.count) playable")
            report.add("Cached MusicKit track payloads", "\(cachedTracks.count)")

            do {
                let remoteTracks = try await PlaylistSyncService().playableMusicTracks(for: playlist, in: context)
                report.add("Selected playlist remote playable tracks", "ok: \(remoteTracks.count)")
                if let firstTrack = remoteTracks.first {
                    report.add("First remote playable track", "\(firstTrack.title) by \(firstTrack.artistName) [\(firstTrack.id.rawValue)]")
                }
            } catch {
                report.add("Selected playlist remote playable tracks", "failed: \(diagnosticDescription(for: error))")
                await probeRemotePlaylistCandidates(named: playlist.name, into: &report)
            }
            return cachedTracks
        } catch {
            report.add("Local selected playlist probe", "failed: \(diagnosticDescription(for: error))")
            return []
        }
    }

    private func probeApplicationMusicPlayer(into report: inout MusicKitDiagnosticsReport) async {
        let player = ApplicationMusicPlayer.shared
        report.add("ApplicationMusicPlayer status", String(describing: player.state.playbackStatus))
        report.add("ApplicationMusicPlayer current entry", player.queue.currentEntry == nil ? "nil" : "present")

        do {
            try await player.prepareToPlay()
            report.add("ApplicationMusicPlayer.prepareToPlay", "ok")
        } catch {
            report.add("ApplicationMusicPlayer.prepareToPlay", "failed: \(diagnosticDescription(for: error))")
        }
    }

    private func probeStoredPlaylistIDAlignment(
        storedID: String,
        name: String?,
        into report: inout MusicKitDiagnosticsReport
    ) async {
        do {
            let libraryPlaylists = try await PlaylistSyncService().fetchLibraryPlaylists()
            let resolvedID = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
                storedID: storedID,
                name: name,
                libraryPlaylists: libraryPlaylists.map { .init(id: $0.id, name: $0.name) }
            )

            if let resolvedID {
                if resolvedID == storedID {
                    report.add("Stored playlist ID in library", "ok")
                } else {
                    report.add(
                        "Stored playlist ID in library",
                        "stale: stored=\(storedID), library=\(resolvedID)"
                    )
                }
            } else {
                report.add("Stored playlist ID in library", "missing")
            }
        } catch {
            report.add("Stored playlist ID in library", "failed: \(diagnosticDescription(for: error))")
        }
    }

    private func probeRemotePlaylistCandidates(named playlistName: String, into report: inout MusicKitDiagnosticsReport) async {
        do {
            let playlists = try await PlaylistSyncService().fetchLibraryPlaylists()
            let candidates = playlists.filter {
                $0.name.localizedCaseInsensitiveCompare(playlistName) == .orderedSame
            }

            if candidates.isEmpty {
                report.add("Remote playlists named \(playlistName)", "none")
            } else {
                let candidateText = candidates
                    .map { "\($0.name) [\($0.id)] tracks=\($0.trackCount.map(String.init) ?? "nil")" }
                    .joined(separator: "; ")
                report.add("Remote playlists named \(playlistName)", candidateText)
            }
        } catch {
            report.add("Remote same-name playlist search", "failed: \(diagnosticDescription(for: error))")
        }
    }

    private func probeCachedPlaybackQueue(cachedTracks: [Track], into report: inout MusicKitDiagnosticsReport) async {
        guard let firstTrack = cachedTracks.first else {
            report.add("Cached one-track queue probe", "skipped: no cached tracks")
            return
        }

        let player = ApplicationMusicPlayer.shared
        player.queue = ApplicationMusicPlayer.Queue(for: [firstTrack], startingAt: firstTrack)
        report.add("Cached one-track queue probe track", "\(firstTrack.title) by \(firstTrack.artistName) [\(firstTrack.id.rawValue)]")

        do {
            try await player.prepareToPlay()
            report.add("Cached one-track queue prepareToPlay", "ok")
            player.pause()
        } catch {
            report.add("Cached one-track queue prepareToPlay", "failed: \(diagnosticDescription(for: error))")
            player.pause()
        }
    }

    private func authorizationStatusDescription(_ status: MusicAuthorization.Status) -> String {
        switch status {
        case .notDetermined:
            "notDetermined"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        case .authorized:
            "authorized"
        @unknown default:
            "unknown"
        }
    }

    private func diagnosticDescription(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.userInfo.isEmpty {
            return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        }

        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
    }
}

private struct MusicKitDiagnosticsReport {
    private var lines: [String] = []

    var text: String {
        lines.joined(separator: "\n")
    }

    mutating func add(_ key: String, _ value: String) {
        lines.append("\(key): \(value)")
    }
}
