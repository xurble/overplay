import Foundation

/// What Overplay asked MusicKit to play (`PLAY-010`).
///
/// Written before the queue is submitted and replaced only by the next
/// submission. No observation, error, timeout or unattributable entry may clear
/// it: it is the one thing Overplay always knows, whatever the player reports.
struct PlaybackIntent: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable, Identifiable {
        var localTrackID: String
        var playlistItemID: UUID?
        /// Every Apple Music identifier this track may be reported under.
        var musicItemIDs: [String]
        var title: String
        var artistName: String
        var albumTitle: String?
        var artworkURLTemplate: String?
        var durationSeconds: Double?

        var id: String { localTrackID }
    }

    var id: UUID
    var createdAt: Date
    var musicPlaylistID: String
    var scope: PlaylistPlaybackScope
    var members: [Member]
    var startingLocalTrackID: String?

    func member(localTrackID: String?) -> Member? {
        guard let localTrackID else { return nil }
        return members.first { $0.localTrackID == localTrackID }
    }

    func index(of localTrackID: String) -> Int? {
        members.firstIndex { $0.localTrackID == localTrackID }
    }
}

/// Where to resume the intent, updated as playback moves. Small and written
/// often, so it lives apart from the intent file.
struct PlaybackResumePoint: Codable, Equatable, Sendable {
    var intentID: UUID
    var localTrackID: String?
    var positionSeconds: Double
    var wasPlaying: Bool
    var updatedAt: Date
}

/// Device-local persistence for the intent and resume point. Never synced.
struct PlaybackIntentStore {
    private static let resumeKey = "overplay.playbackResumePoint.v1"

    let fileURL: URL
    let defaults: UserDefaults

    init(
        fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Overplay/PlaybackIntent.json"),
        defaults: UserDefaults = .standard
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    func loadIntent() -> PlaybackIntent? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PlaybackIntent.self, from: data)
    }

    /// Atomic, so a crash mid-write leaves the previous intent intact.
    func save(_ intent: PlaybackIntent) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(intent).write(to: fileURL, options: .atomic)
    }

    func loadResumePoint() -> PlaybackResumePoint? {
        guard let data = defaults.data(forKey: Self.resumeKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackResumePoint.self, from: data)
    }

    func save(_ resumePoint: PlaybackResumePoint) {
        guard let data = try? JSONEncoder().encode(resumePoint) else { return }
        defaults.set(data, forKey: Self.resumeKey)
    }

    /// Only a database reset clears playback state.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        defaults.removeObject(forKey: Self.resumeKey)
    }
}
