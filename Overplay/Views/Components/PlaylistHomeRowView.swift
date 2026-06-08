import SwiftUI

struct PlaylistHomeRowView: View {
    var title: String
    var detail: String
    var artworkURLString: String?
    var playlistID: String?
    var systemImage: String?
    var badgeTint: Color?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(
                    urlString: artworkURLString,
                    pixelSize: 96,
                    playlistID: playlistID,
                    cornerRadius: 8
                )
                .frame(width: 48, height: 48)

                if let systemImage, let badgeTint {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(badgeTint, in: Circle())
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    PlaylistHomeRowView(
        title: "Overplay",
        detail: "12 tracks",
        artworkURLString: nil,
        playlistID: "preview-playlist",
        systemImage: "play.fill",
        badgeTint: .green
    )
    .padding()
}
