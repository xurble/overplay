import Foundation

/// The reviewed selection travels with the sheet and survives its dismissal.
struct DuplicateMergeRequest: Identifiable {
    let id = UUID()
    let candidates: [DuplicateTrackService.Candidate]

    init?(candidates: [DuplicateTrackService.Candidate], selectedIDs: Set<UUID>) {
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        guard Set(selected.map(\.id)).count >= 2 else { return nil }
        self.candidates = selected
    }

    var suggestedDestination: DuplicateTrackService.Destination? {
        Set(candidates.map(\.destination)).count == 1 ? candidates.first?.destination : nil
    }
}
