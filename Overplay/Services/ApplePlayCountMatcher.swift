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
    struct Index: Sendable {
        private struct MetadataKey: Hashable, Sendable {
            var title: String
            var artist: String
            var album: String
        }
        private let library: [ApplePlayCountLibraryEntry]
        private var aliases: [String: Set<Int>] = [:]
        private var recordings: [String: [Int]] = [:]
        private var metadata: [MetadataKey: [Int]] = [:]

        init(_ library: [ApplePlayCountLibraryEntry]) {
            self.library = library
            for (index, entry) in library.enumerated() {
                for alias in entry.track.aliases where !alias.isEmpty { aliases[alias, default: []].insert(index) }
                if let isrc = normalized(entry.track.isrc) { recordings[isrc, default: []].append(index) }
                if let key = Self.key(entry.track) { metadata[key, default: []].append(index) }
            }
        }

        func matches(_ target: ApplePlayCountMatchTrack, allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
            let direct = target.aliases.reduce(into: Set<Int>()) { $0.formUnion(aliases[$1] ?? []) }.sorted()
            if !direct.isEmpty { return direct.map { library[$0].observation } }
            if allowRecordingCode, let isrc = normalized(target.isrc), let candidates = recordings[isrc], !candidates.isEmpty {
                return unique(candidates.map { library[$0] }.filter { durationAgrees(target.duration, $0.track.duration, required: false) })
            }
            guard let key = Self.key(target) else { return [] }
            return unique((metadata[key] ?? []).map { library[$0] }.filter {
                durationAgrees(target.duration, $0.track.duration, required: true)
                    && !conflictingISRC(target.isrc, $0.track.isrc)
            })
        }

        private static func key(_ track: ApplePlayCountMatchTrack) -> MetadataKey? {
            guard let title = normalized(track.title), let artist = normalized(track.artist), let album = normalized(track.album) else { return nil }
            return MetadataKey(title: title, artist: artist, album: album)
        }
    }

    static func matches(_ target: ApplePlayCountMatchTrack,
                        in library: [ApplePlayCountLibraryEntry],
                        allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
        Index(library).matches(target, allowRecordingCode: allowRecordingCode)
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
