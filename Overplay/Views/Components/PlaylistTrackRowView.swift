import SwiftUI

struct PlaylistTrackRowView: View {
    var summary: TrackSummaryPresentation
    var playlistID: String
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: summary.artworkURLString,
                    pixelSize: 96,
                    playlistID: playlistID,
                    cornerRadius: 8
                )
                .frame(width: 48, height: 48)

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
            }

            Spacer()

            if let skipCountLabel = summary.skipCountLabel {
                Text(skipCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
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
        isCurrent: true
    )
    .padding()
}
