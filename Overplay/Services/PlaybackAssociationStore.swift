import Foundation
import CryptoKit

/// Playback-only evidence. These associations never enter TrackRecord identity
/// or the deduplication graph. Position is deliberately not a persistent key.
enum PlaybackAssociationStore {
    static let key = "overplay.playbackAssociations.v1"

    struct Association: Codable, Equatable {
        var scope: String
        var playerID: String
        var playlistID: String
        var localTrackID: String
        var musicItemID: String
        var localMetadata: PlaybackTrackMatchMetadata
        var reportedMetadata: PlaybackTrackMatchMetadata
        var learnedAt: Date
    }

    static func scopeKey(account: String, storefront: String) -> String {
        SHA256.hash(data: Data("\(account)\n\(storefront)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func validated(
        scope: String, playerID: String, playlistID: String,
        members: [PendingQueueCorrelation], defaults: UserDefaults, now: Date = .now
    ) -> [Association] {
        let records = load(defaults)
        let candidates = records.filter {
            $0.scope == scope && $0.playerID == playerID && $0.playlistID == playlistID
        }
        let valid = candidates.filter { association in
            let owners = members.filter { $0.matches(association.musicItemID) }
            return now.timeIntervalSince(association.learnedAt) < 90 * 24 * 60 * 60
                && now >= association.learnedAt
                && members.contains {
                    $0.localTrackID == association.localTrackID && $0.metadata == association.localMetadata
                }
                && association.localMetadata.matches(association.reportedMetadata)
                && owners.allSatisfy { $0.localTrackID == association.localTrackID }
                && Set(candidates.filter { $0.musicItemID == association.musicItemID }.map(\.localTrackID)).count == 1
        }
        // Stale evidence is removed, so reverting metadata cannot revive it.
        let retained = records.filter { !candidates.contains($0) || valid.contains($0) }
        if retained != records { save(retained, defaults: defaults) }
        return valid
    }

    static func record(_ association: Association, defaults: UserDefaults) {
        record([association], defaults: defaults)
    }

    static func record(_ associations: [Association], defaults: UserDefaults) {
        guard !associations.isEmpty else { return }
        let previous = load(defaults)
        var records = previous
        for association in associations {
            let existing = records.filter {
                $0.scope == association.scope && $0.playerID == association.playerID
                    && $0.playlistID == association.playlistID && $0.musicItemID == association.musicItemID
            }
            // Keep the same competing-owner rejection as the single-record path.
            guard existing.allSatisfy({ $0.localTrackID == association.localTrackID }) else {
                records.removeAll { existing.contains($0) }
                continue
            }
            if existing.contains(where: {
                $0.localMetadata == association.localMetadata && $0.reportedMetadata == association.reportedMetadata
            }) { continue }
            records.removeAll { existing.contains($0) }
            records.append(association)
            if records.count > 2048 { records.removeFirst(records.count - 2048) }
        }
        if records != previous { save(records, defaults: defaults) }
    }

    static func clear(defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    private static func load(_ defaults: UserDefaults) -> [Association] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([Association].self, from: data) else { return [] }
        return records
    }

    private static func save(_ records: [Association], defaults: UserDefaults) {
        let span = PerformanceSpan(.playbackAssociationWrite)
        defer { span.finish(magnitude: Double(records.count)) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
