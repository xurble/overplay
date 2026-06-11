import Foundation

struct PlaybackModeState: Codable, Equatable, Sendable {
    var playerID: String
    var musicPlaylistID: String
    var shuffleEnabled: Bool
    var repeatEnabled: Bool
    var orderedTrackIDs: [String]
    var updatedAt: Date

    init(
        playerID: String,
        musicPlaylistID: String,
        shuffleEnabled: Bool = false,
        repeatEnabled: Bool = false,
        orderedTrackIDs: [String] = [],
        updatedAt: Date = .now
    ) {
        self.playerID = playerID
        self.musicPlaylistID = musicPlaylistID
        self.shuffleEnabled = shuffleEnabled
        self.repeatEnabled = repeatEnabled
        self.orderedTrackIDs = orderedTrackIDs
        self.updatedAt = updatedAt
    }
}

enum PlaybackModeStore {
    private static let key = "overplay.playbackModeStates.v1"

    static func state(
        playerID: String,
        musicPlaylistID: String,
        from defaults: UserDefaults = .standard
    ) -> PlaybackModeState {
        states(from: defaults)[storageKey(playerID: playerID, musicPlaylistID: musicPlaylistID)] ?? PlaybackModeState(
            playerID: playerID,
            musicPlaylistID: musicPlaylistID
        )
    }

    static func save(
        _ state: PlaybackModeState,
        to defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        var states = states(from: defaults)
        var state = state
        state.updatedAt = .now
        states[storageKey(playerID: state.playerID, musicPlaylistID: state.musicPlaylistID)] = state
        save(states, to: defaults, flushImmediately: flushImmediately)
    }

    static func update(
        playerID: String,
        musicPlaylistID: String,
        in defaults: UserDefaults = .standard,
        flushImmediately: Bool = false,
        transform: (inout PlaybackModeState) -> Void
    ) {
        var state = state(playerID: playerID, musicPlaylistID: musicPlaylistID, from: defaults)
        transform(&state)
        save(state, to: defaults, flushImmediately: flushImmediately)
    }

    static func clear(
        playerID: String,
        musicPlaylistID: String,
        from defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        var states = states(from: defaults)
        states.removeValue(forKey: storageKey(playerID: playerID, musicPlaylistID: musicPlaylistID))
        save(states, to: defaults, flushImmediately: flushImmediately)
    }

    static func rekeyMusicPlaylistID(
        from oldID: String,
        to newID: String,
        from defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard oldID != newID else { return }

        let storedStates = states(from: defaults)
        var updatedStates = storedStates

        for (key, var state) in storedStates where state.musicPlaylistID == oldID {
            updatedStates.removeValue(forKey: key)
            state.musicPlaylistID = newID
            updatedStates[storageKey(playerID: state.playerID, musicPlaylistID: newID)] = state
        }

        save(updatedStates, to: defaults, flushImmediately: flushImmediately)
    }

    private static func storageKey(playerID: String, musicPlaylistID: String) -> String {
        "\(playerID)::\(musicPlaylistID)"
    }

    private static func states(from defaults: UserDefaults) -> [String: PlaybackModeState] {
        guard let data = defaults.data(forKey: key) else {
            return [:]
        }

        return (try? JSONDecoder().decode([String: PlaybackModeState].self, from: data)) ?? [:]
    }

    private static func save(
        _ states: [String: PlaybackModeState],
        to defaults: UserDefaults,
        flushImmediately: Bool
    ) {
        guard let data = try? JSONEncoder().encode(states) else {
            return
        }

        defaults.set(data, forKey: key)
        if flushImmediately {
            defaults.synchronize()
        }
    }
}
