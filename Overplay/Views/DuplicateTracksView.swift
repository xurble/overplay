import SwiftData
import SwiftUI

struct DuplicateTracksView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaybackController.self) private var playbackController
    @State private var groups: [DuplicateTrackService.Group] = []
    @State private var selected = Set<UUID>()
    @State private var destination: DuplicateTrackService.Destination?
    @State private var pending: [DuplicateTrackService.Candidate] = []
    @State private var busy = false
    @State private var message: String?
    @State private var showConfirmation = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text("Find possible copies of the same recording. Review the song and album details before merging; remixes, live recordings and edits may be different.")
                Button(busy ? "Scanning…" : "Scan for Duplicates", systemImage: "magnifyingglass") {
                    scanTask = Task { await scan() }
                }
                .disabled(busy)
                if busy { ProgressView() }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { value in
                            if value { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title)
                                Text(candidate.artist + " · " + (candidate.album ?? "Unknown album"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("\(candidate.destination.rawValue) · \(candidate.plays) plays · \(candidate.skips) skips")
                                    .font(.caption)
                            }
                        }
                        .disabled(busy)
                    }
                    Button("Review Selected Merge") {
                        pending = group.candidates.filter { selected.contains($0.id) }
                        destination = Set(pending.map(\.destination)).count == 1 ? pending.first?.destination : nil
                        showConfirmation = true
                    }
                    .disabled(busy || group.candidates.filter { selected.contains($0.id) }.count < 2)
                } header: { Text("Possible duplicates") }
            }
        }
        .navigationTitle("Find Duplicates")
        .sheet(isPresented: $showConfirmation) {
            NavigationStack {
                Form {
                    Section {
                        Text("Merge \(pending.count) tracks into one?")
                        Text("Play and skip counts will be added together. History and source playlists will be preserved.")
                        if Set(pending.map(\.destination)).count > 1 {
                            Picker("Keep in", selection: $destination) {
                                Text("Choose a collection").tag(Optional<DuplicateTrackService.Destination>.none)
                                ForEach(DuplicateTrackService.Destination.allCases) { value in
                                    Text(value.rawValue).tag(Optional(value))
                                }
                            }
                        } else if let destination { Text("Keep in \(destination.rawValue)") }
                    }
                    Section {
                        ForEach(pending) { candidate in
                            LabeledContent(candidate.title, value: candidate.album ?? candidate.artist)
                        }
                    }
                }
                .navigationTitle("Confirm Merge")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showConfirmation = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Merge") {
                            showConfirmation = false
                            Task { await merge() }
                        }.disabled(destination == nil)
                    }
                }
            }
            .frame(minWidth: 320, minHeight: 350)
        }
        .onDisappear { scanTask?.cancel() }
    }

    private func scan() async {
        busy = true
        defer { busy = false }
        do {
            groups = try await DuplicateTrackService.scan(in: context)
            selected.removeAll()
            message = groups.isEmpty ? "No apparent duplicates found." : "Review each group and select the tracks that are the same recording."
        } catch is CancellationError { }
        catch {
            // Existing persisted evidence remains useful while offline.
            groups = (try? DuplicateTrackService.groups(DuplicateTrackService.candidates(in: context))) ?? []
            selected.removeAll()
            message = "Showing local matches. Apple Music lookup failed: \(error.localizedDescription)"
        }
    }

    private func merge() async {
        busy = true
        defer { busy = false }
        do {
            message = try await playbackController.mergeDuplicateTracks(pending, destination: destination, context: context)
            groups = try DuplicateTrackService.groups(DuplicateTrackService.candidates(in: context))
            selected.removeAll()
        } catch { message = error.localizedDescription }
    }
}

#Preview {
    NavigationStack { DuplicateTracksView() }
        .modelContainer(PreviewContainer.make())
        .environment(PlaybackController())
}
