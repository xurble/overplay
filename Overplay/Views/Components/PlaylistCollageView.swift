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
            artwork
            .overlay { if isLoading { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) } }
            .contentShape(Rectangle())
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Artwork for \(playlist.name)")
            .accessibilityHint("Touch and hold for artwork settings, to regenerate or to save to Photos")
            .accessibilityAction(named: "Settings") { showSettings() }
            .accessibilityAction(named: "Regenerate") { regenerate() }
            .accessibilityAction(named: "Save to Photos") { saveToPhotos() }
            .contextMenu {
                Group {
                    Button("Settings", systemImage: "slider.horizontal.3") { showSettings() }
                    Button("Regenerate", systemImage: "arrow.clockwise") { regenerate() }
                    Button("Save to Photos", systemImage: "square.and.arrow.down") { saveToPhotos() }
                        .disabled(image == nil)
                }
                .untinted()
            } preview: {
                // Drawn from the loaded image: the system's own preview of
                // the artwork came up empty.
                artwork
                    .frame(width: 320, height: 320)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .task(id: refreshID) { await load() }
        .onChange(of: playlist.collageSnapshotData(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageLayout(for: scope)) { refreshID = UUID() }
        .onChange(of: playlist.collageStroke(for: scope)) { refreshID = UUID() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshID = UUID() } }
    }

    private var artwork: some View {
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
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    /// The collage as shown: saving never regenerates it (#73).
    private func saveToPhotos() {
        guard let image else { return }
        Task {
            do {
                try await CollagePhotoSaver.save(image)
                StatusToast.shared.show("Saved to Photos. Choose it as the playlist's artwork in the Music app.")
            } catch let error as CollagePhotoSaver.SaveError {
                StatusToast.shared.show(error.localizedDescription)
            } catch {
                StatusToast.shared.show("Couldn't save to Photos. Try again.")
            }
        }
    }

    private func regenerate() {
        regenerateRequested = true
        refreshID = UUID()
    }

    private func load() async {
        isLoading = image == nil
        errorMessage = nil
        let regenerate = regenerateRequested
        regenerateRequested = false
        do {
            let snapshot = try PlaylistCollageService.prepareSnapshot(for: playlist, in: modelContext, scope: scope, regenerate: regenerate)
            let rendered = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlist.musicPlaylistID, scope: scope)
            guard !Task.isCancelled else { return }
            if let rendered { image = rendered }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Could not save artwork settings: \(UserFacingError.message(for: error))"
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
                .untinted()
                Picker("Borders", selection: $stroke) {
                    ForEach(PlaylistCollageStroke.allCases) { Text($0.title).tag($0) }
                }
                .untinted()
                Section {
                    Text("Artwork refreshes when you next open this playlist after 24 hours. Touch and hold the artwork to regenerate it anytime.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Playlist Artwork")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.untinted() }
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
