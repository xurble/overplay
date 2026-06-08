import SwiftData
import SwiftUI

struct PlaylistTrackRowView: View {
    var track: TrackRecord
    @Bindable var item: PlaylistItemRecord
    var playlistID: String
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: track.artworkURLTemplate,
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
                Text(track.title)
                    .font(.headline)
                    .foregroundStyle(item.isPlayable ? .primary : .secondary)
                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let skipCountLabel = presentation.skipCountLabel {
                Text(skipCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var presentation: TrackSummaryPresentation {
        TrackSummaryPresentation(
            id: item.id,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            skipCount: item.skipCount,
            isPlayable: item.isPlayable
        )
    }
}
