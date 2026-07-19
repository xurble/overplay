import Foundation

/// A point-in-time observation of out-of-process playback, persisted so a
/// later wake (background refresh, foregrounding, relaunch) can reconcile
/// what played while Overplay was suspended.
struct PlaybackWaypoint: Codable, Equatable, Sendable {
    var playlistID: String
    var localTrackID: String
    var positionSeconds: Double
    var durationSeconds: Double?
    var recordedAt: Date
    /// Local track ID whose playthrough has already been counted for the
    /// play instance this waypoint observes — the point-proof dedupe ledger.
    var countedLocalTrackID: String? = nil
}

enum PlaybackWaypointStore {
    private static let key = "overplay.playbackWaypoint.v1"

    static func load(from defaults: UserDefaults = .standard) -> PlaybackWaypoint? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(PlaybackWaypoint.self, from: data)
    }

    static func save(
        _ waypoint: PlaybackWaypoint,
        to defaults: UserDefaults = .standard,
        flushImmediately: Bool = false
    ) {
        guard let data = try? JSONEncoder().encode(waypoint) else {
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
}
