import Foundation

/// MusicKit removals replace the entire playlist. Hold the same per-playlist
/// gate for additions and for the complete read/modify/write, across awaits.
@MainActor
final class PlaylistRemoteMutationCoordinator {
    static let shared = PlaylistRemoteMutationCoordinator()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func perform<T>(playlistID: String, operation: () async throws -> T) async throws -> T {
        if waiters[playlistID] != nil {
            await withCheckedContinuation { waiters[playlistID, default: []].append($0) }
        } else {
            waiters[playlistID] = []
        }
        defer {
            if var queue = waiters[playlistID], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[playlistID] = queue
                next.resume()
            } else {
                waiters[playlistID] = nil
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    @discardableResult
    func rewrite<Snapshot>(
        playlistID: String,
        isCurrent: () -> Bool,
        load: () async throws -> Snapshot,
        write: (Snapshot) async throws -> Void
    ) async throws -> Bool {
        try await perform(playlistID: playlistID) {
            guard isCurrent() else { return false }
            let snapshot = try await load()
            try Task.checkCancellation()
            guard isCurrent() else { return false }
            try await write(snapshot)
            return true
        }
    }
}
