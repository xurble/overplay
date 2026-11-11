import Foundation
import Synchronization
@testable import Overplay

/// A `PlaybackClock` that moves only when a test says so (TST-8).
///
/// Time stands still until `advance(by:)`, so a limit can neither fire early
/// on a slow run nor be waited out on the wall clock. `advance` returns once
/// every sleep it ended has resumed, and the code after that sleep has run
/// up to its next suspension: a watchdog's decision is made by then.
nonisolated final class ManualPlaybackClock: Sendable {
    private struct Sleeper {
        var id: Int
        var deadline: Duration
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var elapsed: Duration = .zero
        var sleepers: [Sleeper] = []
        var nextID = 0
        /// Sleeps ended by `advance` whose task has resumed.
        var resumed = 0
    }

    private let origin = ContinuousClock.now
    private let state = Mutex(State())

    var clock: PlaybackClock {
        PlaybackClock(now: { [self] in now }, sleep: { [self] in await sleep(for: $0) })
    }

    var now: ContinuousClock.Instant { origin + state.withLock { $0.elapsed } }

    /// How many sleeps of exactly `duration` from now are pending: a limit
    /// that has just started.
    func pending(_ duration: Duration) -> Int {
        state.withLock { state in state.sleepers.filter { $0.deadline - state.elapsed == duration }.count }
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Ends every sleep due by the new time, earliest first, and returns once
    /// each of their tasks has resumed.
    @MainActor
    func advance(by duration: Duration) async {
        let (due, target) = state.withLock { state in
            state.elapsed += duration
            let elapsed = state.elapsed
            let due = state.sleepers.filter { $0.deadline <= elapsed }.sorted { $0.deadline < $1.deadline }
            state.sleepers.removeAll { $0.deadline <= elapsed }
            return (due.map(\.continuation), state.resumed + due.count)
        }
        due.forEach { $0.resume(returning: true) }
        while state.withLock({ $0.resumed }) < target { await Task.yield() }
    }

    /// Sleeps until `advance` passes the deadline; returns at once when the
    /// task is cancelled, as the continuous clock's sleep does.
    @MainActor
    func sleep(for duration: Duration) async {
        guard duration > .zero else { return }
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        let ended = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let cancelled = state.withLock { state in
                    if Task.isCancelled { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: state.elapsed + duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(returning: false) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index).continuation
            }
            continuation?.resume(returning: false)
        }
        // In the same job as the code after the caller's sleep, so `advance`
        // sees this only once that code has reached its next suspension.
        if ended { state.withLock { $0.resumed += 1 } }
    }
}
