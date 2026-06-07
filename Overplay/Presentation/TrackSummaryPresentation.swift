import Foundation

struct TrackSummaryPresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let artistName: String
    let albumTitle: String?
    let skipCount: Int

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
