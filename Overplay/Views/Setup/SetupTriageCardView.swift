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
                    .accessibilityHidden(true)
                Text("Fill the Inbox")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Choose playlists that feed the Inbox. Their new songs arrive there for you to review.")
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
                Section {
                    ForEach(viewModel.suggestedSources) { row(for: $0) }
                } header: {
                    Label("Suggested", systemImage: "sparkles")
                }
            }
            if !viewModel.otherSources.isEmpty {
                Section {
                    ForEach(viewModel.otherSources) { row(for: $0) }
                } header: {
                    if !viewModel.suggestedSources.isEmpty { Text("Your Playlists") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .tint(.teal)
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading playlists")
            } else if viewModel.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                    description: Text("Add Inbox sources later in Settings."))
            }
        }
    }

    private func row(for playlist: AppleMusicPlaylist) -> some View {
        let isOn = viewModel.triageSourceIDs.contains(playlist.id)
        return Button {
            withAnimation(.smooth(duration: 0.2)) {
                viewModel.setTriageSource(playlist, isOn: !isOn, context: modelContext, dependencies: dependencies)
            }
        } label: {
            SetupPlaylistRowView(playlist: playlist, details: viewModel.playlistDetails[playlist.id], isSelected: isOn)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 12))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isOn ? Color.teal.opacity(0.16) : .clear)
                .padding(.horizontal, 2)
        )
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
