import Foundation

/// MusicKit removals replace the entire playlist. Hold the same per-playlist
/// gate for additions and for the complete read/modify/write, across awaits.
@MainActor
final class PlaylistRemoteMutationCoordinator {
    static let shared = PlaylistRemoteMutationCoordinator()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Songs on their way into a playlist, from before they queue for the gate
    /// until their local move is done. On these rows a stale-OTP suppression
    /// means "promotion in flight", not "this song must leave".
    private var addsInFlight: [String: [UUID]] = [:]

    /// `addingTrack` marks an add that ends in a local move. The move belongs
    /// inside `operation`, so the mark ends with the gate.
    func perform<T>(playlistID: String, addingTrack trackID: UUID? = nil, operation: () async throws -> T) async throws -> T {
        if let trackID { addsInFlight[playlistID, default: []].append(trackID) }
        if waiters[playlistID] != nil {
            await withCheckedContinuation { waiters[playlistID, default: []].append($0) }
        } else {
            waiters[playlistID] = []
        }
        defer {
            if let trackID, let index = addsInFlight[playlistID]?.firstIndex(of: trackID) {
                addsInFlight[playlistID]?.remove(at: index)
            }
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

    func tracksBeingAdded(to playlistID: String) -> [UUID] { addsInFlight[playlistID] ?? [] }

    /// Operations queued behind the one holding the gate; nil when it is free.
    func waitingCount(playlistID: String) -> Int? { waiters[playlistID]?.count }

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
