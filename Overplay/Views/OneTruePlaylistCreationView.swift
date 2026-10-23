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
                viewModel.restoreProgress(context: modelContext)
                await viewModel.loadPlaylists(dependencies: dependencies)
            }
            .onChange(of: viewModel.message) { _, message in
                guard let message else { return }
                StatusToast.shared.show(message)
                viewModel.message = nil
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
