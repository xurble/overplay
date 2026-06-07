import Foundation

struct LocalPlaybackState: Codable, Equatable, Sendable {
    var playlistID: String
    var musicItemID: String
    var elapsedSeconds: Double
    var wasPlaying: Bool
    var updatedAt: Date
    var localTrackID: String? = nil
}

enum LocalPlaybackStateStore {
    private static let key = "overplay.localPlaybackState"

    static func load(from defaults: UserDefaults = .standard) -> LocalPlaybackState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(LocalPlaybackState.self, from: data)
    }

    static func save(_ state: LocalPlaybackState, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
