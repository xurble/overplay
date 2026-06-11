import Foundation

struct LocalPlaybackState: Codable, Equatable, Sendable {
    var playlistID: String
    var musicItemID: String
    var elapsedSeconds: Double
    var wasPlaying: Bool
    var updatedAt: Date
    var localTrackID: String? = nil
}

enum LocalPlaybackStateFlushPolicy {
    static let playingFlushInterval: TimeInterval = 15

    static func shouldFlush(
        now: Date,
        lastFlushAt: Date?,
        isPlaying: Bool,
        didChangePlaybackIdentity: Bool,
        force: Bool
    ) -> Bool {
        if force || didChangePlaybackIdentity {
            return true
        }

        guard isPlaying else {
            return false
        }

        guard let lastFlushAt else {
            return true
        }

        return now.timeIntervalSince(lastFlushAt) >= playingFlushInterval
    }
}

enum LocalPlaybackStateStore {
    private static let key = "overplay.localPlaybackState"

    static func load(from defaults: UserDefaults = .standard) -> LocalPlaybackState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(LocalPlaybackState.self, from: data)
    }

    static func save(
        _ state: LocalPlaybackState,
        to defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: key)
        if flushImmediately {
            defaults.synchronize()
        }
    }

    static func clear(from defaults: UserDefaults = .standard, flushImmediately: Bool = false) {
        defaults.removeObject(forKey: key)
        if flushImmediately {
            defaults.synchronize()
        }
    }

    static func rekeyMusicPlaylistID(
        from oldID: String,
        to newID: String,
        from defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard oldID != newID, var state = load(from: defaults), state.playlistID == oldID else {
            return
        }

        state.playlistID = newID
        save(state, to: defaults, flushImmediately: flushImmediately)
    }
}
