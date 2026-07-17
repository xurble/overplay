import Foundation

struct TrackSummaryPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    var playlistID: UUID?
    var trackID: UUID?
    let title: String
    let artistName: String
    let albumTitle: String?
    var artworkURLString: String?
    let skipCount: Int
    var playthroughCount: Int = 0
    var isPlayable: Bool = true
    var isRetired: Bool = false

    var subtitle: String {
        guard let albumTitle, !albumTitle.isEmpty else {
            return artistName
        }

        return "\(artistName) - \(albumTitle)"
    }

    var skipCountLabel: String? {
        guard skipCount > 0 else { return nil }
        return skipCount == 1 ? "1 skip" : "\(skipCount) skips"
    }

    var playSkipMetricLabel: String {
        "\(Self.pluralized(playthroughCount, singular: "play")) / \(Self.pluralized(skipCount, singular: "skip"))"
    }

    var detailText: String {
        if isRetired {
            "\(artistName) - Retired - \(playSkipMetricLabel)"
        } else {
            "\(artistName) - \(playSkipMetricLabel)"
        }
    }

    private static func pluralized(_ count: Int, singular: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
    }
}
