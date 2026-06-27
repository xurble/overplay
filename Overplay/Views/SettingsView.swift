import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playbackController

    @Bindable var settings: OverplaySettings
    @State private var showResetConfirmation = false
    @State private var showNukeConfirmation = false
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.selectedPlaylistName ?? "None")
                            .font(.body)
                        SettingsSubtitle(
                            "Your One True Playlist. Evictions and triage promotions are manual."
                        )
                    }
                    Spacer()
                    NavigationLink("Change") {
                        PlaylistSelectionView()
                    }
                }
            } header: {
                Text("Monitored Playlist")
            }

            Section {
                SettingsSliderRow(
                    title: "Skip threshold: \(Int(settings.skipThresholdPercentage))%",
                    subtitle: "An early skip counts only if playback stops before this percentage of the track.",
                    value: $settings.skipThresholdPercentage,
                    range: 1...99,
                    step: 1
                )

                SettingsSliderRow(
                    title: "Minimum listening time: \(Int(settings.minimumSkipListeningSeconds)) seconds",
                    subtitle: "Playback must reach this duration before an early skip can be counted.",
                    value: $settings.minimumSkipListeningSeconds,
                    range: 0...60,
                    step: 1
                )

                SettingsSliderRow(
                    title: "Playthrough threshold: \(Int(settings.playthroughThresholdPercentage))%",
                    subtitle: "Listening past this percentage counts as a full playthrough instead of a skip.",
                    value: $settings.playthroughThresholdPercentage,
                    range: 1...100,
                    step: 1
                )
            } header: {
                Text("Tracking Rules")
            } footer: {
                Text("Skip and playthrough counts are tracked for all linked playlists. Skips in the neutral middle of a track do not change either count.")
                    .font(.caption)
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    SettingsActionLabel(
                        title: "Reset All Local Overplay Stats",
                        subtitle: "Clears skip, playthrough, protection, and eviction state without changing Apple Music playlists.",
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }

            Section {
                Button(role: .destructive) {
                    showNukeConfirmation = true
                } label: {
                    SettingsActionLabel(
                        title: "Nuke Database",
                        subtitle: "Deletes all Overplay records locally and syncs those deletions through iCloud.",
                        systemImage: "trash"
                    )
                }
            } header: {
                Text("Database")
            }

            Section {
                Button {
                    Task { await runMusicKitDiagnostics() }
                } label: {
                    SettingsActionLabel(
                        title: viewModel.isRunningMusicKitDiagnostics ? "Running MusicKit Diagnostics" : "Run MusicKit Diagnostics",
                        subtitle: "Checks Apple Music authorization, playlist access, and playback readiness.",
                        systemImage: "waveform.path.ecg"
                    )
                }
                .disabled(viewModel.isRunningMusicKitDiagnostics)

                if let musicKitDiagnosticsReport = viewModel.musicKitDiagnosticsReport {
                    Text(musicKitDiagnosticsReport)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Diagnostics")
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Settings")
        .onDisappear {
            viewModel.saveIfNeeded(settings: settings, context: modelContext, dependencies: dependencies)
        }
        .confirmationDialog("Reset all local stats?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Local Stats", role: .destructive) {
                resetStats()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears Overplay skip, playthrough, protection, and eviction state. It does not delete Apple Music playlist content.")
        }
        .confirmationDialog("Nuke local and iCloud data?", isPresented: $showNukeConfirmation, titleVisibility: .visible) {
            Button("Nuke Database", role: .destructive) {
                nukeDatabase()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes Overplay records locally and saves the deletions so iCloud can sync them. Apple Music playlists are not deleted.")
        }
    }

    private func resetStats() {
        if viewModel.resetStats(context: modelContext, dependencies: dependencies) {
            dismiss()
        }
    }

    private func nukeDatabase() {
        if viewModel.nukeDatabase(context: modelContext, dependencies: dependencies) {
            dismiss()
        }
    }

    private func runMusicKitDiagnostics() async {
        await viewModel.runMusicKitDiagnostics(
            settings: settings,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private var dependencies: SettingsViewModel.Dependencies {
        .live(playbackController: playbackController)
    }
}

private struct SettingsSubtitle: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsLabeledStepper: View {
    var title: String
    var subtitle: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }

            HStack {
                Spacer()
                Stepper(value: $value, in: range) {
                    EmptyView()
                }
                .accessibilityLabel(title)
            }
        }
    }
}

private struct SettingsSliderRow: View {
    var title: String
    var subtitle: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }

            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct SettingsLabeledToggle: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }
        }
    }
}

private struct SettingsActionLabel: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .modelContainer(PreviewContainer.make())
    .environment(PlaybackController())
}
