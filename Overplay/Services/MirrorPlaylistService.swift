import Foundation
@preconcurrency import MusicKit

enum MirrorPlaylistError: LocalizedError, Equatable {
    case noPlayableTracks
    case mirrorUnavailable

    var errorDescription: String? {
        switch self {
        case .noPlayableTracks:
            "No playable tracks remain after local retirements."
        case .mirrorUnavailable:
            "Overplay could not prepare its Apple Music queue playlist."
        }
    }
}

@MainActor
protocol MirrorPlaylistProviding {
    /// Returns a playlist holding exactly `tracks`, in that order, ready to be
    /// handed to the player.
    func mirroredPlaylist(
        for sourcePlaylistID: String,
        scope: PlaylistPlaybackScope,
        tracks: [Track],
        linkedPlaylistIDs: [String]
    ) async throws -> Playlist
}

/// Maintains the Apple Music playlist Overplay plays from.
///
/// Handing the player a `Playlist` rather than a materialized track list is
/// what lets Apple Music own shuffle, repeat, and queue paging. The user's own
/// playlists cannot be used for this, because Overplay's retirement state is
/// local and must not rewrite what the user curated — so Overplay keeps one
/// disposable mirror playlist and rewrites that instead.
@MainActor
struct MirrorPlaylistService: MirrorPlaylistProviding {
    var playlistFetcher: any MusicLibraryPlaylistFetching = CachingMusicLibraryPlaylistFetcher.shared
    var defaults: UserDefaults = .standard

    /// Rewrites the mirror only when its contents have actually drifted from
    /// what is wanted, so repeatedly replaying a playlist costs no library
    /// writes at all.
    func mirroredPlaylist(
        for sourcePlaylistID: String,
        scope: PlaylistPlaybackScope,
        tracks: [Track],
        linkedPlaylistIDs: [String]
    ) async throws -> Playlist {
        guard !tracks.isEmpty else {
            throw MirrorPlaylistError.noPlayableTracks
        }

        let desiredMusicItemIDs = tracks.map(\.id.rawValue)
        let state = storedState(linkedPlaylistIDs: linkedPlaylistIDs)
        let needsRewrite = MirrorPlaylistPolicy.needsRewrite(
            desiredMusicItemIDs: desiredMusicItemIDs,
            sourcePlaylistID: sourcePlaylistID,
            scope: scope.rawValue,
            state: state
        )

        if let state, let existing = try await existingMirror(id: state.musicPlaylistID) {
            guard needsRewrite else {
                return existing
            }

            let updated = try await MusicKitActivityLog.shared.measure(
                .libraryPlaylistEdit,
                magnitude: Double(tracks.count),
                detail: "rewrote Overplay mirror playlist"
            ) {
                try await MusicLibrary.shared.edit(existing, items: tracks)
            }
            save(updated, sourcePlaylistID: sourcePlaylistID, scope: scope, musicItemIDs: desiredMusicItemIDs)
            return updated
        }

        let created = try await MusicKitActivityLog.shared.measure(
            .libraryPlaylistCreate,
            magnitude: Double(tracks.count),
            detail: "created Overplay mirror playlist"
        ) {
            try await MusicLibrary.shared.createPlaylist(
                name: MirrorPlaylistPolicy.playlistName,
                description: MirrorPlaylistPolicy.playlistDescription,
                items: tracks
            )
        }
        save(created, sourcePlaylistID: sourcePlaylistID, scope: scope, musicItemIDs: desiredMusicItemIDs)
        return created
    }

    /// Forgets the mirror so the next play rebuilds it. Used when the stored
    /// mirror turns out to be missing or unsafe to write to.
    func invalidate() {
        MirrorPlaylistStore.clear(from: defaults)
    }

    private func storedState(linkedPlaylistIDs: [String]) -> MirrorPlaylistState? {
        guard let state = MirrorPlaylistStore.load(from: defaults) else {
            return nil
        }

        // A mirror ID that has come to collide with a playlist the user linked
        // must never be the target of a rewriting edit.
        guard MirrorPlaylistPolicy.isSafeMirrorTarget(
            mirrorPlaylistID: state.musicPlaylistID,
            linkedPlaylistIDs: linkedPlaylistIDs
        ) else {
            MirrorPlaylistStore.clear(from: defaults)
            return nil
        }

        return state
    }

    private func existingMirror(id playlistID: String) async throws -> Playlist? {
        do {
            return try await playlistFetcher.fetchPlaylist(id: playlistID)
        } catch {
            // A lookup failure is not evidence the mirror is gone, so leave the
            // stored state alone and let the caller fall back to a track queue.
            throw error
        }
    }

    private func save(
        _ playlist: Playlist,
        sourcePlaylistID: String,
        scope: PlaylistPlaybackScope,
        musicItemIDs: [String]
    ) {
        MirrorPlaylistStore.save(
            MirrorPlaylistState(
                musicPlaylistID: playlist.id.rawValue,
                sourcePlaylistID: sourcePlaylistID,
                scope: scope.rawValue,
                writtenMusicItemIDs: musicItemIDs
            ),
            to: defaults
        )
    }
}
