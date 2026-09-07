import Foundation

struct TrackStateBadgePresentation: Equatable, Sendable {
    let isEvicted: Bool

    var title: String {
        isEvicted ? "Retired" : "Active"
    }

    var systemImage: String {
        isEvicted ? "trash.fill" : "music.note"
    }
}
