import SwiftUI

struct PlaylistTrackRowView: View {
    var summary: TrackSummaryPresentation
    var playlistID: String
    var isCurrent: Bool
    var loadsArtworkImmediately = true

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: summary.artworkURLString,
                    pixelSize: 144,
                    playlistID: playlistID,
                    cornerRadius: 0,
                    loadsImmediately: loadsArtworkImmediately
                )
                .frame(width: 72, height: 72)

                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.green, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(summary.isPlayable ? .primary : .secondary)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let provenanceText = summary.provenanceText {
                    Text(provenanceText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(summary.playSkipMetricLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    PlaylistTrackRowView(
        summary: TrackSummaryPresentation(
            id: UUID(),
            title: "Soft Machine",
            artistName: "Glass Coast",
            albumTitle: "Late Light",
            artworkURLString: nil,
            skipCount: 2,
            isPlayable: true
        ),
        playlistID: "preview-playlist",
        isCurrent: true,
        loadsArtworkImmediately: true
    )
    .padding()
}
