import SwiftData
import SwiftUI

/// Makes the One True Playlist for a library that has none, with setup's
/// card (`SETUP-001`): Overplay creates it, empty or as a copy, because only
/// a playlist it created can be edited later. On a Mac the card asks an
/// iPhone or iPad to make it (`SETUP-002`).
struct OneTruePlaylistCreationView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SetupViewModel()

    var body: some View {
        SetupOneTruePlaylistCardView(viewModel: viewModel, dependencies: dependencies)
            .padding()
            .navigationTitle("One True Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await makeRequestedPlaylist()
                viewModel.restoreProgress(context: modelContext, dependencies: dependencies)
                await viewModel.loadPlaylists(dependencies: dependencies)
            }
            .onChange(of: viewModel.message) { _, message in
                guard let message else { return }
                StatusToast.shared.show(message)
                viewModel.message = nil
            }
    }

    /// A Mac asked for it: a device that can make it does so now, with the
    /// Mac's choice, rather than asking again. A failure leaves the card's
    /// own Copy and Start Empty.
    private func makeRequestedPlaylist() async {
        guard dependencies.canCreatePlaylists(),
              let settings = try? modelContext.fetch(FetchDescriptor<OverplaySettings>()).first,
              settings.pendingOneTruePlaylistRequestedAt != nil, settings.selectedPlaylistID == nil else { return }
        viewModel.isCreatingOneTruePlaylist = true
        await runtime.fulfilPendingOneTruePlaylist(in: modelContext)
        viewModel.isCreatingOneTruePlaylist = false
        if settings.selectedPlaylistID == nil {
            viewModel.message = "Overplay couldn’t make the playlist your Mac asked for. Check your connection, or make one below."
        }
    }

    private var dependencies: SetupViewModel.Dependencies {
        .live(runtime: runtime, playbackController: playbackController)
    }
}

#Preview {
    NavigationStack {
        OneTruePlaylistCreationView()
    }
    .environment(AppRuntime.shared)
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
