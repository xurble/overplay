import SwiftData
import SwiftUI

/// Creates the One True Playlist: a new managed "Overplay" playlist in Apple
/// Music, empty or with a copy of an existing playlist's songs.
struct SetupOneTruePlaylistCardView: View {
    @Bindable var viewModel: SetupViewModel
    let dependencies: SetupViewModel.Dependencies

    @Environment(\.modelContext) private var modelContext
    @State private var isChoosingSource = false

    var body: some View {
        SetupCardView {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                // Every state's symbol, faded between: the symbol replace
                // morphed the arrow into the tick outside its circle.
                ZStack {
                    ForEach(Self.symbols, id: \.self) { name in
                        Image(systemName: name)
                            .font(.system(size: 72, weight: .semibold))
                            .foregroundStyle(name == Self.doneSymbol ? .green : .pink)
                            .symbolRenderingMode(.hierarchical)
                            .opacity(name == symbol ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.45), value: symbol)
                .accessibilityHidden(true)
                Text(title)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // The buttons keep their space once used, so the tick and its
                // text stay put rather than dropping into the gap.
                let showsActions = !viewModel.isCreatingOneTruePlaylist && !viewModel.hasChosenOneTruePlaylist
                actions
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                    .accessibilityHidden(!showsActions)
                    .overlay {
                        if viewModel.isCreatingOneTruePlaylist {
                            ProgressView("Creating Overplay")
                        }
                    }
            }
        }
        .sheet(isPresented: $isChoosingSource) {
            SetupPlaylistPickerView(playlists: viewModel.playlists, details: viewModel.playlistDetails, isLoading: viewModel.isLoading) { source in
                Task { await viewModel.createOneTruePlaylist(copying: source, context: modelContext, dependencies: dependencies) }
            }
        }
    }

    private static let startSymbol = "arrow.up.circle.fill"
    private static let doneSymbol = "checkmark.circle.fill"
    private static let requestedSymbol = "iphone.and.arrow.forward"
    private static let symbols = [startSymbol, doneSymbol, requestedSymbol]

    private var symbol: String {
        if viewModel.isOneTruePlaylistRequested { return Self.requestedSymbol }
        return viewModel.hasOneTruePlaylist ? Self.doneSymbol : Self.startSymbol
    }

    private var title: String {
        if viewModel.isOneTruePlaylistRequested { return "Finish on iPhone" }
        return viewModel.hasOneTruePlaylist ? "Overplay Is Ready" : "Your One True Playlist"
    }

    private var detail: String {
        if viewModel.isOneTruePlaylistRequested {
            let songs = viewModel.copiedFrom.map { "with the songs from \($0)" } ?? "empty"
            return "A Mac can't create Apple Music playlists. The next time you open Overplay on your iPhone or iPad, it makes the Overplay playlist, \(songs)."
        }
        if viewModel.hasOneTruePlaylist {
            if let source = viewModel.copiedFrom {
                return "Overplay is a new Apple Music playlist with the songs from \(source). \(source) itself is unchanged."
            }
            return "Overplay is a new, empty Apple Music playlist. Promote songs to it from the Inbox, or add them from Search."
        }
        return "Overplay makes a new Apple Music playlist called Overplay, and updates it as you promote and retire songs. Copy the songs from a playlist you already have, or start empty."
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isChoosingSource = true
            } label: {
                Label("Copy a Playlist", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            // Filled: purple text on glass is illegible on a dark background.
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            Button {
                Task { await viewModel.createOneTruePlaylist(copying: nil, context: modelContext, dependencies: dependencies) }
            } label: {
                Label("Start Empty", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            // Filled: purple text on glass is illegible on a dark background.
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}

#Preview {
    SetupOneTruePlaylistCardView(
        viewModel: SetupViewModel(),
        dependencies: .live(runtime: AppRuntime.shared, playbackController: PlaybackController())
    )
    .padding()
    .modelContainer(PreviewContainer.make())
}
