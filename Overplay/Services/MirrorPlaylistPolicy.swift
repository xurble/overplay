import Foundation

/// State of the Apple Music playlist Overplay plays from on the user's behalf.
struct MirrorPlaylistState: Codable, Equatable, Sendable {
    var musicPlaylistID: String
    var sourcePlaylistID: String
    var scope: String
    var writtenMusicItemIDs: [String]
    var updatedAt: Date

    init(
        musicPlaylistID: String,
        sourcePlaylistID: String,
        scope: String,
        writtenMusicItemIDs: [String],
        updatedAt: Date = .now
    ) {
        self.musicPlaylistID = musicPlaylistID
        self.sourcePlaylistID = sourcePlaylistID
        self.scope = scope
        self.writtenMusicItemIDs = writtenMusicItemIDs
        self.updatedAt = updatedAt
    }
}

/// Rules for the mirror playlist: an Apple Music playlist Overplay owns,
/// containing exactly the tracks that are playable right now.
///
/// Overplay hands the player this playlist as an entity instead of a list of
/// tracks, so Apple Music can own shuffle and repeat while local retirement
/// still decides what is in the queue. The mirror is disposable and always
/// rebuildable from SwiftData, which is what makes the whole-playlist rewrite
/// that `MusicLibrary.edit(_:items:)` requires safe to point at it — the same
/// rewrite aimed at a user's own playlist risks real data loss.
enum MirrorPlaylistPolicy {
    static let playlistName = "Overplay Queue"
    static let playlistDescription = "Managed by Overplay. Contents are replaced automatically."

    /// A mirror can be reused untouched only when it already holds exactly the
    /// tracks wanted, in the same order, for the same playlist and scope.
    static func needsRewrite(
        desiredMusicItemIDs: [String],
        sourcePlaylistID: String,
        scope: String,
        state: MirrorPlaylistState?
    ) -> Bool {
        guard let state else {
            return true
        }

        return state.sourcePlaylistID != sourcePlaylistID
            || state.scope != scope
            || state.writtenMusicItemIDs != desiredMusicItemIDs
    }

    /// Guards against ever pointing the rewriting edit at a playlist the user
    /// linked. A mirror that collides with a linked playlist is discarded and
    /// recreated rather than written to.
    static func isSafeMirrorTarget(
        mirrorPlaylistID: String,
        linkedPlaylistIDs: some Sequence<String>
    ) -> Bool {
        !mirrorPlaylistID.isEmpty && !linkedPlaylistIDs.contains(mirrorPlaylistID)
    }
}

enum MirrorPlaylistStore {
    private static let key = "overplay.mirrorPlaylistState.v1"

    static func load(from defaults: UserDefaults = .standard) -> MirrorPlaylistState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(MirrorPlaylistState.self, from: data)
    }

    static func save(_ state: MirrorPlaylistState, to defaults: UserDefaults = .standard) {
        var state = state
        state.updatedAt = .now
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
