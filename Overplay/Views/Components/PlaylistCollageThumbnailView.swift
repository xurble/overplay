import SwiftData
import SwiftUI

/// A compact display of the same cached PNG used by playlist detail and CarPlay.
struct PlaylistCollageThumbnailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    var playlist: PlaylistRecord
    var scope: PlaylistPlaybackScope = .active
    @State private var image: CGImage?
    @State private var refreshID = UUID()

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "music.note.list").foregroundStyle(.secondary) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
        .task(id: refreshID) {
            guard let snapshot = try? PlaylistCollageService.snapshot(for: playlist, in: modelContext, scope: scope) else { return }
            let rendered = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlist.musicPlaylistID, scope: scope)
            guard !Task.isCancelled else { return }
            image = rendered
        }
        .onChange(of: playlist.collageSnapshotData(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageLayout(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageStroke(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.updatedAt) { refreshID = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshID = UUID() } }
    }
}

#Preview {
    PlaylistCollageThumbnailView(playlist: PlaylistRecord(musicPlaylistID: "preview", name: "Favorites"))
        .frame(width: 72, height: 72)
        .modelContainer(PreviewContainer.make())
        .padding()
}
