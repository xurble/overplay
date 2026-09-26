import SwiftUI

struct PlaylistHomeRowView: View {
    var title: String
    var detail: String
    var playlist: PlaylistRecord? = nil
    var scope: PlaylistPlaybackScope = .active
    var systemImage: String?
    var badgeTint: Color?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let playlist {
                        PlaylistCollageThumbnailView(playlist: playlist, scope: scope)
                    } else {
                        ArtworkView(pixelSize: 128, cornerRadius: 0)
                    }
                }
                .frame(width: 96, height: 96)

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
            .padding(.vertical, 12)

            Spacer()
        }
    }
}

#Preview {
    PlaylistHomeRowView(
        title: "Overplay",
        detail: "12 tracks",
        systemImage: "play.fill",
        badgeTint: .green
    )
    .padding()
}
