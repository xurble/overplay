import Foundation

enum TrackHealthStatus: Equatable, Sendable {
    case healthy
    case caution
    case critical

    static func resolve(
        skipCount: Int,
        evictAfterSkips: Int,
        isEvicted: Bool,
        isProtected: Bool
    ) -> TrackHealthStatus {
        if isProtected {
            return .healthy
        }
        if isEvicted {
            return .critical
        }
        if skipCount == 0 {
            return .healthy
        }
        if skipCount < max(evictAfterSkips - 1, 1) {
            return .caution
        }
        return .critical
    }
}
