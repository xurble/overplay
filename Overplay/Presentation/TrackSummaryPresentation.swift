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
    var isPlayable: Bool = true
    var healthStatus: TrackHealthStatus?

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

    var detailText: String {
        guard let skipCountLabel else {
            return artistName
        }

        return "\(artistName) - \(skipCountLabel)"
    }
}
