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
    var provenanceText: String? = nil
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
        var details = [artistName]
        if isRetired { details.append("Retired") }
        if let provenanceText { details.append(provenanceText) }
        details.append(playSkipMetricLabel)
        return details.joined(separator: " - ")
    }

    static func provenanceText(
        sourceMusicPlaylistIDs: [String],
        playlistRole: PlaylistRole?,
        sourcePlaylists: [PlaylistRecord]
    ) -> String? {
        guard playlistRole == .triageBucket else { return nil }
        guard !sourceMusicPlaylistIDs.isEmpty else { return "Unattributed" }

        let namesByMusicPlaylistID = sourcePlaylists.reduce(into: [String: String]()) { result, playlist in
            result[playlist.musicPlaylistID] = playlist.name
        }
        let names = sourceMusicPlaylistIDs.map {
            namesByMusicPlaylistID[$0] ?? "Unknown Playlist"
        }
        return "From \(names.joined(separator: ", "))"
    }

    private static func pluralized(_ count: Int, singular: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
    }
}
