import Foundation

struct PlaybackIdentityState: Codable, Equatable, Sendable {
    var playerID: String
    var musicPlaylistID: String
    var aliasesByLocalTrackID: [String: [String]]
    var updatedAt: Date

    init(
        playerID: String,
        musicPlaylistID: String,
        aliasesByLocalTrackID: [String: [String]] = [:],
        updatedAt: Date = .now
    ) {
        self.playerID = playerID
        self.musicPlaylistID = musicPlaylistID
        self.aliasesByLocalTrackID = aliasesByLocalTrackID
        self.updatedAt = updatedAt
    }
}

enum PlaybackIdentityStore {
    private static let key = "overplay.playbackIdentityStates.v1"
    private static let maximumAliasesPerTrack = 16

    static func state(
        playerID: String,
        musicPlaylistID: String,
        from defaults: UserDefaults = .standard
    ) -> PlaybackIdentityState {
        states(from: defaults)[storageKey(playerID: playerID, musicPlaylistID: musicPlaylistID)] ?? PlaybackIdentityState(
            playerID: playerID,
            musicPlaylistID: musicPlaylistID
        )
    }

    static func aliases(
        playerID: String,
        musicPlaylistID: String,
        localTrackID: String,
        from defaults: UserDefaults = .standard
    ) -> [String] {
        state(
            playerID: playerID,
            musicPlaylistID: musicPlaylistID,
            from: defaults
        ).aliasesByLocalTrackID[localTrackID] ?? []
    }

    static func localTrackID(
        matching musicItemID: String,
        playerID: String,
        musicPlaylistID: String,
        candidateLocalTrackIDs: Set<String>,
        from defaults: UserDefaults = .standard
    ) -> String? {
        let matches = state(
            playerID: playerID,
            musicPlaylistID: musicPlaylistID,
            from: defaults
        )
        .aliasesByLocalTrackID
        .compactMap { localTrackID, aliases -> String? in
            guard candidateLocalTrackIDs.contains(localTrackID),
                  aliases.contains(musicItemID) else {
                return nil
            }

            return localTrackID
        }

        return matches.count == 1 ? matches[0] : nil
    }

    static func recordAlias(
        _ musicItemID: String,
        playerID: String,
        musicPlaylistID: String,
        localTrackID: String,
        to defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard !musicItemID.isEmpty else { return }

        update(
            playerID: playerID,
            musicPlaylistID: musicPlaylistID,
            in: defaults,
            flushImmediately: flushImmediately
        ) { state in
            var aliases = state.aliasesByLocalTrackID[localTrackID] ?? []
            guard !aliases.contains(musicItemID) else { return }
            aliases.append(musicItemID)
            if aliases.count > maximumAliasesPerTrack {
                aliases.removeFirst(aliases.count - maximumAliasesPerTrack)
            }
            state.aliasesByLocalTrackID[localTrackID] = aliases
        }
    }

    static func update(
        playerID: String,
        musicPlaylistID: String,
        in defaults: UserDefaults = .standard,
        flushImmediately: Bool = false,
        transform: (inout PlaybackIdentityState) -> Void
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

    static func clearAll(from defaults: UserDefaults = .standard, flushImmediately: Bool = false) {
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

    /// Rewrites alias keys after a track identity merge, combining alias
    /// lists when duplicates collapse onto the same canonical track.
    static func rekeyLocalTrackIDs(
        _ mapping: [String: String],
        from defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard !mapping.isEmpty else { return }

        let storedStates = states(from: defaults)
        var updatedStates = storedStates
        var didChange = false

        for (key, var state) in storedStates {
            guard state.aliasesByLocalTrackID.keys.contains(where: { mapping[$0] != nil }) else { continue }

            var mergedAliases: [String: [String]] = [:]
            for (localTrackID, aliases) in state.aliasesByLocalTrackID {
                let newKey = mapping[localTrackID] ?? localTrackID
                var combined = mergedAliases[newKey] ?? []
                for alias in aliases where !combined.contains(alias) {
                    combined.append(alias)
                }
                if combined.count > maximumAliasesPerTrack {
                    combined.removeFirst(combined.count - maximumAliasesPerTrack)
                }
                mergedAliases[newKey] = combined
            }
            state.aliasesByLocalTrackID = mergedAliases
            updatedStates[key] = state
            didChange = true
        }

        if didChange {
            save(updatedStates, to: defaults, flushImmediately: flushImmediately)
        }
    }

    private static func storageKey(playerID: String, musicPlaylistID: String) -> String {
        "\(playerID)::\(musicPlaylistID)"
    }

    private static func states(from defaults: UserDefaults) -> [String: PlaybackIdentityState] {
        guard let data = defaults.data(forKey: key) else {
            return [:]
        }

        return (try? JSONDecoder().decode([String: PlaybackIdentityState].self, from: data)) ?? [:]
    }

    private static func save(
        _ state: PlaybackIdentityState,
        to defaults: UserDefaults,
        flushImmediately: Bool
    ) {
        var states = states(from: defaults)
        var state = state
        state.updatedAt = .now
        states[storageKey(playerID: state.playerID, musicPlaylistID: state.musicPlaylistID)] = state
        save(states, to: defaults, flushImmediately: flushImmediately)
    }

    private static func save(
        _ states: [String: PlaybackIdentityState],
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
