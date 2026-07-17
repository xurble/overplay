import Foundation

enum PlaybackOrderCoordinator {
    static func orderedTrackIDs(
        orderTracks: [PlaybackOrderTrack],
        playerID: String,
        playlistID: String,
        retainedTrackID: String? = nil,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let state = reconciledState(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            retainedTrackID: retainedTrackID,
            defaults: defaults
        )
        return state.orderedTrackIDs
    }

    @discardableResult
    static func reshuffle(
        playerID: String,
        playlistID: String,
        orderTracks: [PlaybackOrderTrack],
        avoiding avoidedTrackID: String?,
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let orderedTrackIDs = PlaybackOrderEngine.reshuffledOrder(
            for: orderTracks,
            avoiding: avoidedTrackID
        )
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: playlistID,
                orderedTrackIDs: orderedTrackIDs
            ),
            to: defaults,
            flushImmediately: flushImmediately
        )
        return orderedTrackIDs
    }

    @discardableResult
    static func appendTrackIDs(
        _ trackIDs: [String],
        playerID: String,
        playlistID: String,
        orderTracks: [PlaybackOrderTrack],
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let state = PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: playlistID, from: defaults)
        let existing = Set(state.orderedTrackIDs)
        let available = Set(PlaybackOrderEngine.normalOrder(for: orderTracks))
        let appended = trackIDs.filter { available.contains($0) && !existing.contains($0) }
        guard !appended.isEmpty else {
            return state.orderedTrackIDs
        }

        let orderedTrackIDs = state.orderedTrackIDs + appended
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: playlistID,
                orderedTrackIDs: orderedTrackIDs
            ),
            to: defaults,
            flushImmediately: flushImmediately
        )
        return orderedTrackIDs
    }

    @discardableResult
    static func removeTrackIDs(
        _ trackIDs: Set<String>,
        playerID: String,
        playlistID: String,
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard
    ) -> [String] {
        let state = PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: playlistID, from: defaults)
        let orderedTrackIDs = state.orderedTrackIDs.filter { !trackIDs.contains($0) }
        guard orderedTrackIDs != state.orderedTrackIDs else {
            return state.orderedTrackIDs
        }

        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: playlistID,
                orderedTrackIDs: orderedTrackIDs
            ),
            to: defaults,
            flushImmediately: flushImmediately
        )
        return orderedTrackIDs
    }

    @discardableResult
    static func reconciledState(
        orderTracks: [PlaybackOrderTrack],
        playerID: String,
        playlistID: String,
        retainedTrackID: String? = nil,
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard
    ) -> PlaybackOrderState {
        var state = PlaybackOrderStore.state(playerID: playerID, musicPlaylistID: playlistID, from: defaults)
        let orderedTrackIDs = PlaybackOrderEngine.reconciledOrder(
            storedOrder: state.orderedTrackIDs,
            tracks: orderTracks,
            includeUnplayableTrackID: retainedTrackID
        )
        if state.orderedTrackIDs != orderedTrackIDs {
            state.orderedTrackIDs = orderedTrackIDs
            PlaybackOrderStore.save(state, to: defaults, flushImmediately: flushImmediately)
        }
        return state
    }

    static func updateOrder(
        playerID: String,
        playlistID: String,
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard,
        transform: (inout [String]) -> Void
    ) {
        PlaybackOrderStore.update(
            playerID: playerID,
            musicPlaylistID: playlistID,
            in: defaults,
            flushImmediately: flushImmediately
        ) { state in
            transform(&state.orderedTrackIDs)
        }
    }

    static func moveTrackIDToBottom(
        _ trackID: String,
        playerID: String,
        playlistID: String,
        items: [PlaylistItemRecord],
        targetScope: PlaylistPlaybackScope,
        flushImmediately: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        for scope in PlaylistPlaybackScope.allCases {
            let scopedPlaylistID = scope.playbackOrderPlaylistID(for: playlistID)
            let scopedItems = items.filter { scope.includes($0) }
            let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope)
            let storedOrder = PlaybackOrderStore.state(
                playerID: playerID,
                musicPlaylistID: scopedPlaylistID,
                from: defaults
            ).orderedTrackIDs
            var orderedTrackIDs = PlaybackOrderEngine.reconciledOrder(
                storedOrder: storedOrder,
                tracks: orderTracks
            ).filter { $0 != trackID }

            if scope == targetScope,
               scopedItems.contains(where: { $0.trackID.uuidString == trackID }) {
                orderedTrackIDs.append(trackID)
            }

            PlaybackOrderStore.save(
                PlaybackOrderState(
                    playerID: playerID,
                    musicPlaylistID: scopedPlaylistID,
                    orderedTrackIDs: orderedTrackIDs
                ),
                to: defaults,
                flushImmediately: flushImmediately
            )
        }
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
