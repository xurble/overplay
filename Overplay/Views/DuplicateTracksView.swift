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
                } header: {
                    Text(group.reason == .sameRecording ? "Same recording" : "Same name and artist: check before merging")
                }
            }
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Find Duplicates")
        .sheet(item: $mergeRequest) { request in
            DuplicateMergeConfirmationView(request: request) { destination in
                mergeRequest = nil
                Task { await merge(request, destination: destination) }
            }
        }
        .onDisappear { scanTask?.cancel() }
    }

    /// What Overplay knows first, at once; then Apple Music, only for the
    /// songs that match by name alone.
    private func scan() async {
        busy = true
        defer { busy = false }
        do {
            groups = try DuplicateTrackService.localScan(in: context)
        } catch {
            message = UserFacingError.message(for: error)
            return
        }
        selected.removeAll()
        let nameOnly = groups.filter { $0.reason == .sameNameAndArtist }.reduce(0) { $0 + $1.candidates.count }
        guard nameOnly > 0 else {
            message = groups.isEmpty ? "No apparent duplicates found." : "Review each group and select the tracks that are the same recording."
            return
        }
        message = "Checking \(nameOnly == 1 ? "1 song" : "\(nameOnly) songs") that match by name with Apple Music…"
        do {
            let result = try await DuplicateTrackService.confirmNameMatches(groups, in: context)
            groups = result.groups
            selected.removeAll()
            message = groups.isEmpty ? "No apparent duplicates found." : "Review each group and select the tracks that are the same recording."
            if result.uncheckedCount > 0 {
                let songs = result.uncheckedCount == 1 ? "1 song" : "\(result.uncheckedCount) songs"
                message = (message ?? "") + " Apple Music couldn’t check \(songs), so they were matched on what Overplay already knew."
            }
        } catch is CancellationError {
        } catch {
            // The local groups stand; only the name matches went unconfirmed.
            message = "Showing what Overplay knows. Apple Music couldn’t check the name matches: \(UserFacingError.message(for: error))"
        }
    }

    private func merge(_ request: DuplicateMergeRequest, destination: DuplicateTrackService.Destination) async {
        busy = true
        defer { busy = false }
        do {
            message = try await playbackController.mergeDuplicateTracks(request.candidates, destination: destination, context: context)
            groups = try DuplicateTrackService.groups(DuplicateTrackService.candidates(in: context))
            selected.removeAll()
        } catch { message = UserFacingError.message(for: error) }
    }
}

#Preview {
    NavigationStack { DuplicateTracksView() }
        .modelContainer(PreviewContainer.make())
        .environment(PlaybackController())
}
