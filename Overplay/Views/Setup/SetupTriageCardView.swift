import SwiftData
import SwiftUI

/// Chooses the playlists that feed Triage, suggesting the ones Apple Music
/// fills by itself (TikTok Songs, Shazam) first.
struct SetupTriageCardView: View {
    @Bindable var viewModel: SetupViewModel
    let dependencies: SetupViewModel.Dependencies
    let onSkip: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        SetupCardView {
            VStack(spacing: 12) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.teal)
                Text("Fill Triage")
                    .font(.title.bold())
                Text("Choose playlists that feed Triage. Their new songs arrive here for you to review.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                playlistList
                if viewModel.triageSourceIDs.isEmpty {
                    Button("Add Sources Later", action: onSkip)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
            }
        }
    }

    private var playlistList: some View {
        List {
            if !viewModel.suggestedSources.isEmpty {
                Section("Suggested") {
                    ForEach(viewModel.suggestedSources) { row(for: $0) }
                }
            }
            Section(viewModel.suggestedSources.isEmpty ? "" : "Your Playlists") {
                ForEach(viewModel.otherSources) { row(for: $0) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading playlists")
            } else if viewModel.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                    description: Text("Add Triage sources later from Linked Playlists."))
            }
        }
    }

    private func row(for playlist: AppleMusicPlaylist) -> some View {
        let isOn = viewModel.triageSourceIDs.contains(playlist.id)
        return Button {
            viewModel.setTriageSource(playlist, isOn: !isOn, context: modelContext, dependencies: dependencies)
        } label: {
            HStack {
                SetupPlaylistRowView(playlist: playlist)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? .teal : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .tint(.primary)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

#Preview {
    SetupTriageCardView(
        viewModel: SetupViewModel(),
        dependencies: .live(runtime: AppRuntime.shared, playbackController: PlaybackController()),
        onSkip: {}
    )
    .padding()
    .modelContainer(PreviewContainer.make())
}
