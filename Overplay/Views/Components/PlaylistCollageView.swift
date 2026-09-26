import SwiftData
import SwiftUI

struct PlaylistCollageView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlaylistArtworkPresentation.self) private var artworkPresentation
    @Bindable var playlist: PlaylistRecord
    var scope: PlaylistPlaybackScope = .active
    @State private var image: CGImage?
    @State private var errorMessage: String?
    @State private var refreshID = UUID()
    @State private var regenerateRequested = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 64)).foregroundStyle(.secondary)
                        }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 420)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { if isLoading { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) } }
            .contentShape(Rectangle())
            .accessibilityLabel("Artwork for \(playlist.name)")
            .accessibilityHint("Touch and hold for artwork settings or to regenerate")
            .accessibilityAction(named: "Settings") { showSettings() }
            .accessibilityAction(named: "Regenerate") { regenerate() }
            .contextMenu {
                Button("Settings", systemImage: "slider.horizontal.3") { showSettings() }
                Button("Regenerate", systemImage: "arrow.clockwise") { regenerate() }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .task(id: refreshID) { await load() }
        .onChange(of: playlist.collageSnapshotData(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageLayout(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageStroke(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.updatedAt) { refreshID = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshID = UUID() } }
    }

    private func showSettings() {
        artworkPresentation.request = PlaylistArtworkPresentation.Request(
            layout: playlist.collageLayout(for: scope), stroke: playlist.collageStroke(for: scope)
        ) { layout, stroke in
            guard playlist.collageLayout(for: scope) != layout
                || playlist.collageStroke(for: scope) != stroke else { return }
            playlist.setCollageTemplate(layout: layout, stroke: stroke, for: scope)
            regenerate()
        }
    }

    private func regenerate() {
        regenerateRequested = true
        refreshID = UUID()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let regenerate = regenerateRequested
        regenerateRequested = false
        do {
            let snapshot = try PlaylistCollageService.snapshot(for: playlist, in: modelContext, scope: scope, regenerate: regenerate)
            let rendered = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlist.musicPlaylistID, scope: scope)
            guard !Task.isCancelled else { return }
            image = rendered
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Could not save artwork settings: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

struct PlaylistCollageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var layout: PlaylistCollageLayout
    @State var stroke: PlaylistCollageStroke
    var save: (PlaylistCollageLayout, PlaylistCollageStroke) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Layout", selection: $layout) {
                    ForEach(PlaylistCollageLayout.allCases) { Text($0.title).tag($0) }
                }
                Picker("Borders", selection: $stroke) {
                    ForEach(PlaylistCollageStroke.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    Text("Artwork refreshes when you next open this playlist after 24 hours. Touch and hold the artwork to regenerate it anytime.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Playlist Artwork")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(layout, stroke); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    PlaylistCollageView(playlist: PlaylistRecord(musicPlaylistID: "preview", name: "Favorites"))
        .modelContainer(PreviewContainer.make())
        .environment(PlaylistArtworkPresentation()).padding()
}

#Preview("Artwork Settings") {
    PlaylistCollageSettingsView(layout: .pile, stroke: .none) { _, _ in }
}
