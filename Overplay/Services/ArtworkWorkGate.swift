import Foundation

/// One permit is handed directly to the highest-priority waiter; equal priorities
/// retain FIFO order. Shared image jobs finish even if one row stops awaiting them.
actor ArtworkWorkGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(TaskPriority, CheckedContinuation<Void, Never>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire(priority: TaskPriority) async {
        guard active >= limit else { active += 1; return }
        await withCheckedContinuation { waiters.append((priority, $0)) }
    }

    func release() {
        guard !waiters.isEmpty else { active -= 1; return }
        let highestPriority = waiters.map { $0.0.rawValue }.max()!
        let index = waiters.firstIndex { $0.0.rawValue == highestPriority }!
        waiters.remove(at: index).1.resume()
    }
}
