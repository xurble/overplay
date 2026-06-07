import Foundation

struct TrackHealthPresentation: Equatable, Sendable {
    let status: TrackHealthStatus
    let isEvicted: Bool
    let isProtected: Bool

    var title: String {
        if isProtected {
            return "Protected"
        }
        if isEvicted {
            return "Evicted"
        }

        return switch status {
        case .healthy:
            "Healthy"
        case .caution:
            "Caution"
        case .critical:
            "At risk"
        }
    }

    var systemImage: String {
        if isProtected {
            return "shield.fill"
        }
        if isEvicted {
            return "trash.fill"
        }

        return switch status {
        case .healthy:
            "checkmark.circle.fill"
        case .caution:
            "exclamationmark.triangle.fill"
        case .critical:
            "exclamationmark.octagon.fill"
        }
    }
}
