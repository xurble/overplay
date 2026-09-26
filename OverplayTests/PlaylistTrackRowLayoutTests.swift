import SwiftUI
import Testing
import UIKit
@testable import Overplay

@MainActor
struct PlaylistTrackRowLayoutTests {
    @Test(arguments: [280.0, 360.0, 700.0])
    func longMetadataDoesNotIncreaseRowHeight(width: Double) {
        let short = rowHeight(title: "Song", artist: "Artist", album: "Album", width: width)
        let long = rowHeight(
            title: String(repeating: "A very long song title ", count: 8) + "(Live) [Remastered]",
            artist: String(repeating: "An artist with a long name ", count: 5) + "[UK]",
            album: String(repeating: "A very long album title ", count: 5) + "(Deluxe)",
            width: width
        )
        #expect(abs(short - long) < 1)
    }

    private func rowHeight(title: String, artist: String, album: String, width: Double) -> Double {
        var summary = TrackSummaryPresentation(
            id: UUID(), title: title, artistName: artist, albumTitle: album, skipCount: 12
        )
        summary.provenanceText = String(repeating: "From a contributing playlist ", count: 6)
        let host = UIHostingController(rootView:
            PlaylistTrackRowView(summary: summary, playlistID: "test", isCurrent: true)
                .environment(\.dynamicTypeSize, .large)
        )
        return host.sizeThatFits(in: CGSize(width: width, height: 1_000)).height
    }
}
