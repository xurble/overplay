import Foundation

enum PlaybackModeCoordinator {
    static func orderedTrackIDs(
        orderTracks: [PlaybackOrderTrack],
        playerID: String,
        playlistID: String,
        startingTrackID: String? = nil,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        defaults: UserDefaults = .standard
    ) -> [String] {
        var state = PlaybackModeStore.state(playerID: playerID, musicPlaylistID: playlistID, from: defaults)

        if state.shuffleEnabled {
            let orderedTrackIDs: [String]
            if promoteStartingTrackInShuffle, let startingTrackID {
                orderedTrackIDs = PlaybackOrderEngine.shuffleOrder(
                    for: orderTracks,
                    currentTrackID: startingTrackID
                )
            } else {
                orderedTrackIDs = PlaybackOrderEngine.reconciledShuffleOrder(
                    storedOrder: state.orderedTrackIDs,
                    tracks: orderTracks,
                    currentTrackID: retainedTrackID
                )
            }
            state.orderedTrackIDs = orderedTrackIDs
            PlaybackModeStore.save(state, to: defaults)
            return orderedTrackIDs
        }

        return PlaybackOrderEngine.normalOrder(
            for: orderTracks,
            includeUnplayableTrackID: retainedTrackID
        )
    }

    static func setShuffleEnabled(
        _ isEnabled: Bool,
        playerID: String,
        playlistID: String,
        orderTracks: [PlaybackOrderTrack],
        currentLocalTrackID: String?,
        defaults: UserDefaults = .standard
    ) {
        PlaybackModeStore.update(playerID: playerID, musicPlaylistID: playlistID, in: defaults) { state in
            state.shuffleEnabled = isEnabled
            state.orderedTrackIDs = if isEnabled {
                PlaybackOrderEngine.shuffleOrder(
                    for: orderTracks,
                    currentTrackID: currentLocalTrackID
                )
            } else {
                []
            }
        }
    }

    static func setRepeatEnabled(
        _ isEnabled: Bool,
        playerID: String,
        playlistID: String,
        defaults: UserDefaults = .standard
    ) {
        PlaybackModeStore.update(playerID: playerID, musicPlaylistID: playlistID, in: defaults) { state in
            state.repeatEnabled = isEnabled
        }
    }

    static func repeatRestartOrder(
        orderTracks: [PlaybackOrderTrack],
        playerID: String,
        playlistID: String,
        lastLocalTrackID: String?,
        defaults: UserDefaults = .standard
    ) -> (orderedTrackIDs: [String], didUpdateStoredShuffleOrder: Bool) {
        var state = PlaybackModeStore.state(playerID: playerID, musicPlaylistID: playlistID, from: defaults)

        if state.shuffleEnabled {
            let orderedTrackIDs = if let lastLocalTrackID {
                PlaybackOrderEngine.repeatShuffleOrder(
                    for: orderTracks,
                    lastPlayedTrackID: lastLocalTrackID
                )
            } else {
                PlaybackOrderEngine.shuffleOrder(for: orderTracks, currentTrackID: nil)
            }
            state.orderedTrackIDs = orderedTrackIDs
            PlaybackModeStore.save(state, to: defaults)
            return (orderedTrackIDs, true)
        }

        return (PlaybackOrderEngine.normalOrder(for: orderTracks), false)
    }

    static func reconciledStoredOrder(
        storedOrder: [String],
        orderTracks: [PlaybackOrderTrack],
        currentTrackID: String?
    ) -> [String] {
        PlaybackOrderEngine.reconciledShuffleOrder(
            storedOrder: storedOrder,
            tracks: orderTracks,
            currentTrackID: currentTrackID
        )
    }

    static func adjacentAvailableID(
        to localTrackID: String,
        orderedLocalTrackIDs: [String],
        availableIDs: Set<String>,
        movingForward: Bool
    ) -> String? {
        PlaybackOrderEngine.adjacentAvailableID(
            to: localTrackID,
            in: orderedLocalTrackIDs,
            availableIDs: availableIDs,
            movingForward: movingForward
        )
    }
}
