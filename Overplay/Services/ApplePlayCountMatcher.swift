import Foundation

/// Library discovery is specific to the comparison count. A metadata match
/// does not change playback identity or authorize merging track records.
nonisolated struct ApplePlayCountMatchTrack: Sendable {
    var aliases: [String]
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var isrc: String?
}

nonisolated struct ApplePlayCountLibraryEntry: Sendable {
    var track: ApplePlayCountMatchTrack
    var observation: MusicLibraryPlaybackObservation
}

nonisolated enum ApplePlayCountMatcher {
    static func matches(_ target: ApplePlayCountMatchTrack,
                        in library: [ApplePlayCountLibraryEntry],
                        allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
        let aliases = Set(target.aliases.filter { !$0.isEmpty })
        let direct = library.filter { !aliases.isDisjoint(with: $0.track.aliases) }
        if !direct.isEmpty { return direct.map(\.observation) }

        if allowRecordingCode, let isrc = normalized(target.isrc) {
            let recordings = library.filter { normalized($0.track.isrc) == isrc }
            if !recordings.isEmpty {
                return unique(recordings.filter { durationAgrees(target.duration, $0.track.duration, required: false) })
            }
        }

        guard let title = normalized(target.title), let artist = normalized(target.artist),
              let album = normalized(target.album) else { return [] }
        return unique(library.filter {
            normalized($0.track.title) == title && normalized($0.track.artist) == artist
                && normalized($0.track.album) == album
                && durationAgrees(target.duration, $0.track.duration, required: true)
                && !conflictingISRC(target.isrc, $0.track.isrc)
        })
    }

    private static func unique(_ entries: [ApplePlayCountLibraryEntry]) -> [MusicLibraryPlaybackObservation] {
        // Include entries with missing counts when checking ambiguity. Otherwise
        // whichever duplicate happens to expose a count would win by accident.
        guard Set(entries.map { $0.observation.snapshot.musicItemID }).count == 1 else { return [] }
        return entries.map(\.observation)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func conflictingISRC(_ left: String?, _ right: String?) -> Bool {
        guard let left = normalized(left), let right = normalized(right) else { return false }
        return left != right
    }

    private static func durationAgrees(_ left: Double?, _ right: Double?, required: Bool) -> Bool {
        guard let left, let right, left.isFinite, right.isFinite, left > 0, right > 0 else { return !required }
        return abs(left - right) <= 2
    }
}
