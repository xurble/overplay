import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playbackController

    @Bindable var settings: OverplaySettings
    @State private var showResetConfirmation = false
    @State private var showNukeConfirmation = false
    @State private var didNukeDatabase = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Monitored Playlist") {
                HStack {
                    Text(settings.selectedPlaylistName ?? "None")
                    Spacer()
                    NavigationLink("Change") {
                        PlaylistSelectionView()
                    }
                }
            }

            Section("Eviction Rules") {
                Stepper("Evict after \(settings.evictAfterSkips) skips", value: $settings.evictAfterSkips, in: 1...20)

                VStack(alignment: .leading) {
                    Text("Skip threshold: \(Int(settings.skipThresholdPercentage))%")
                    Slider(value: $settings.skipThresholdPercentage, in: 1...99, step: 1)
                }

                VStack(alignment: .leading) {
                    Text("Minimum listening time: \(Int(settings.minimumSkipListeningSeconds)) seconds")
                    Slider(value: $settings.minimumSkipListeningSeconds, in: 0...60, step: 1)
                }

                VStack(alignment: .leading) {
                    Text("Playthrough threshold: \(Int(settings.playthroughThresholdPercentage))%")
                    Slider(value: $settings.playthroughThresholdPercentage, in: 1...100, step: 1)
                }

                Toggle("Playthrough resets skip count", isOn: $settings.playthroughResetsSkipCount)
                Toggle("Protect kept tracks from eviction", isOn: $settings.protectKeptTracks)
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset All Local Overplay Stats", systemImage: "arrow.counterclockwise")
                }
            }

            Section("Database") {
                Button(role: .destructive) {
                    showNukeConfirmation = true
                } label: {
                    Label("Nuke Database", systemImage: "trash")
                }
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onDisappear {
            guard !didNukeDatabase else { return }
            try? SettingsRepository.save(settings, in: modelContext)
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
        do {
            try TrackRepository.resetStats(in: modelContext)
            message = "Local stats reset."
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func nukeDatabase() {
        do {
            try DatabaseResetService.nukeDatabase(in: modelContext)
            didNukeDatabase = true
            playbackController.clearLocalStateAfterDatabaseReset()
            message = "Database nuked."
            dismiss()
        } catch {
            message = error.localizedDescription
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
