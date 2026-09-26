import SwiftData
import SwiftUI

struct DuplicateTracksView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaybackController.self) private var playbackController
    @State private var groups: [DuplicateTrackService.Group] = []
    @State private var selected = Set<UUID>()
    @State private var mergeRequest: DuplicateMergeRequest?
    @State private var busy = false
    @State private var message: String?
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
                                Text("\(candidate.destination.rawValue) · \(PlayCountPresentation.metric(overplay: candidate.plays, apple: candidate.applePlays, skips: candidate.skips))")
                                    .font(.caption)
                            }
                        }
                        .disabled(busy)
                    }
                    Button("Review Selected Merge") {
                        mergeRequest = DuplicateMergeRequest(candidates: group.candidates, selectedIDs: selected)
                    }
                    .disabled(busy || group.candidates.filter { selected.contains($0.id) }.count < 2)
                } header: { Text("Possible duplicates") }
            }
        }
        .navigationTitle("Find Duplicates")
        .sheet(item: $mergeRequest) { request in
            DuplicateMergeConfirmationView(request: request) { destination in
                mergeRequest = nil
                Task { await merge(request, destination: destination) }
            }
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

    private func merge(_ request: DuplicateMergeRequest, destination: DuplicateTrackService.Destination) async {
        busy = true
        defer { busy = false }
        do {
            message = try await playbackController.mergeDuplicateTracks(request.candidates, destination: destination, context: context)
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
