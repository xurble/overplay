import Foundation

enum PersistenceMutation: Equatable {
    case inserted
    case updated
    case unchanged

    var didChange: Bool {
        self != .unchanged
    }

    var logName: String {
        switch self {
        case .inserted:
            "inserted"
        case .updated:
            "updated"
        case .unchanged:
            "unchanged"
        }
    }
}

struct TrackRecordUpsertResult {
    let record: TrackRecord
    let mutation: PersistenceMutation
    let shouldWarmUpArtworkTheme: Bool
}

struct PlaylistItemUpsertResult {
    let record: PlaylistItemRecord
    let mutation: PersistenceMutation
}
