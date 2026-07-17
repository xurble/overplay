import Foundation

struct TrackStateBadgePresentation: Equatable, Sendable {
    let isEvicted: Bool
    let isProtected: Bool

    var title: String {
        if isProtected {
            return "Protected"
        }
        if isEvicted {
            return "Retired"
        }
        return "Active"
    }

    var systemImage: String {
        if isProtected {
            return "shield.fill"
        }
        if isEvicted {
            return "trash.fill"
        }
        return "music.note"
    }
}
