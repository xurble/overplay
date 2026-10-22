import SwiftData
import SwiftUI

/// First-run setup (`SETUP-001`): swipeable cards walking through Overplay's
/// features, then creating the One True Playlist and choosing Triage's
/// sources. Shown when the store is empty and may start a new library.
struct SetupView: View {
    let onFinish: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController
    @State private var viewModel = SetupViewModel()
    @State private var page = SetupPage.welcome

    var body: some View {
        VStack(spacing: 16) {
            TabView(selection: $page) {
                ForEach(viewModel.reachablePages) { page in
                    card(for: page)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 44)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            nextButton
                .padding(.horizontal, 20)
        }
        .padding(.vertical)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .task {
            #if DEBUG
            // The first-run build's store is local, so show what the iCloud
            // check would have found for this account.
            if AppPersistence.isFirstRunBuild, let identifier = CloudLibraryProbe.entitledContainerIdentifier {
                let state = await CloudLibraryProbe.check(containerIdentifier: identifier)
                StatusToast.shared.show("iCloud library check: \(state)")
            }
            #endif
            viewModel.restoreProgress(context: modelContext)
            await viewModel.loadPlaylists(dependencies: dependencies)
        }
        // Startup restores a library that arrived from iCloud meanwhile.
        .onChange(of: viewModel.foundExistingLibrary) { _, found in
            if found { onFinish() }
        }
        .onChange(of: viewModel.message) { _, message in
            guard let message else { return }
            StatusToast.shared.show(message)
            viewModel.message = nil
        }
    }

    @ViewBuilder
    private func card(for page: SetupPage) -> some View {
        switch page {
        case .oneTruePlaylist:
            SetupOneTruePlaylistCardView(viewModel: viewModel, dependencies: dependencies)
        case .triage:
            SetupTriageCardView(viewModel: viewModel, dependencies: dependencies) {
                viewModel.skipTriage()
                advance()
            }
        default:
            if let feature = page.feature {
                SetupFeatureCardView(feature: feature, footnote: page == .welcome ? welcomeFootnote : nil)
            }
        }
    }

    private var nextButton: some View {
        Button {
            if page.next != nil {
                advance()
            } else if viewModel.finish(context: modelContext, dependencies: dependencies) {
                onFinish()
            }
        } label: {
            Text(page.next == nil ? "Start Listening" : "Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(viewModel.isCreatingOneTruePlaylist || !viewModel.isDecided(page))
    }

    private func advance() {
        guard let next = page.next else { return }
        withAnimation(.smooth) { page = next }
    }

    /// iCloud may still hold a library this device has not seen.
    private var welcomeFootnote: String? {
        AppPersistence.cloudEnabled
            ? "Already use Overplay on another device? Open it there first, so your library reaches iCloud."
            : nil
    }

    private var dependencies: SetupViewModel.Dependencies {
        .live(runtime: runtime, playbackController: playbackController)
    }
}

enum SetupPage: Int, CaseIterable, Identifiable {
    case welcome, oneTruePlaylistIntro, triageIntro, retired, carPlay, oneTruePlaylist, triage, done

    var id: Int { rawValue }

    var next: SetupPage? { SetupPage(rawValue: rawValue + 1) }

    var feature: SetupFeature? {
        switch self {
        case .welcome:
            SetupFeature(symbol: "music.note.list", tint: .pink, title: "Welcome to Overplay",
                text: "Overplay keeps your favourite music fresh. Listen as you always do: it notices what you play through and what you skip.")
        case .oneTruePlaylistIntro:
            SetupFeature(symbol: "star.circle.fill", tint: .pink, title: "One True Playlist",
                text: "Your main playlist, the one you play most. Every song keeps its plays and skips, so you can see what has earned its place.")
        case .triageIntro:
            SetupFeature(symbol: "tray.fill", tint: .teal, title: "Triage",
                text: "New music lands here from playlists you choose. Promote the songs you love to your One True Playlist and retire the rest.")
        case .retired:
            SetupFeature(symbol: "archivebox.fill", tint: .gray, title: "Retired",
                text: "Retiring a song takes it out of rotation without losing it. Its history stays, and you can play it or bring it back at any time.")
        case .carPlay:
            SetupFeature(symbol: "car.fill", tint: .blue, title: "CarPlay and Siri",
                text: "Promote, retire and undo from CarPlay's Now Playing, or ask Siri to \u{201C}Play Overplay\u{201D}. Your playlists stay tidy with your phone in your pocket.")
        case .done:
            SetupFeature(symbol: "checkmark.circle.fill", tint: .green, title: "You're Set",
                text: "Play your One True Playlist or Triage from the main screen or CarPlay. Linked playlists can be changed at any time in Settings.")
        case .oneTruePlaylist, .triage:
            nil
        }
    }
}

#Preview {
    SetupView(onFinish: {})
        .environment(AppRuntime.shared)
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
