import SwiftUI

struct DuplicateMergeConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var destination: DuplicateTrackService.Destination?
    let request: DuplicateMergeRequest
    let onMerge: (DuplicateTrackService.Destination) -> Void

    init(request: DuplicateMergeRequest, onMerge: @escaping (DuplicateTrackService.Destination) -> Void) {
        self.request = request
        self.onMerge = onMerge
        _destination = State(initialValue: request.suggestedDestination)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Merge \(request.candidates.count) tracks into one?")
                    Text("Overplay plays and skips will be added together. Shared Apple Music counter increases will be counted once. History and source playlists will be preserved.")
                    if request.suggestedDestination == nil {
                        Picker("Keep in", selection: $destination) {
                            Text("Choose a collection").tag(Optional<DuplicateTrackService.Destination>.none)
                            ForEach(DuplicateTrackService.Destination.allCases) { value in
                                Text(value.rawValue).tag(Optional(value))
                            }
                        }
                    } else if let destination {
                        Text("Keep in \(destination.rawValue)")
                    }
                }
                Section {
                    ForEach(request.candidates) { candidate in
                        LabeledContent(candidate.title, value: candidate.album ?? candidate.artist)
                    }
                }
            }
            .navigationTitle("Confirm Merge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        guard let destination else { return }
                        onMerge(destination)
                    }
                    .disabled(destination == nil)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 350)
    }
}

#Preview {
    let candidates = (1...2).map { index in
        DuplicateTrackService.Candidate(
            id: UUID(), itemID: UUID(), title: "good 4 u", artist: "Olivia Rodrigo",
            album: index == 1 ? "SOUR" : "SOUR (Video Version)", destination: .otp,
            playlistID: UUID(), aliases: [], equivalents: [], plays: 0, skips: 0
        )
    }
    if let request = DuplicateMergeRequest(candidates: candidates, selectedIDs: Set(candidates.map(\.id))) {
        DuplicateMergeConfirmationView(request: request) { _ in }
    }
}
