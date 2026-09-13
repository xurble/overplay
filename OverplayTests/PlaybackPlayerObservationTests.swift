import Combine
import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Player invalidation observation", .serialized)
struct PlaybackPlayerObservationTests {
    @Test("will-change bursts are delivered after values change and coalesced")
    func coalescesAfterPublication() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        defer { observer.stop() }
        var values: [Int] = []
        var batches: [Set<PlaybackPlayerChange>] = []
        observer.start { changes in
            values.append(source.value)
            batches.append(changes)
        }
        for _ in 0..<20 { source.queue.changes.send() }
        source.state.send()
        source.value = 42
        #expect(values.isEmpty)
        try await eventually { !values.isEmpty }
        #expect(values == [42])
        #expect(batches == [[.queue, .state]])
    }

    @Test("queue replacement cancels old observation and binds the new queue")
    func rebindsQueue() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        defer { observer.stop() }
        var batches: [Set<PlaybackPlayerChange>] = []
        observer.start { batches.append($0) }
        let oldQueue = source.queue
        // An already scheduled old callback must also be discarded.
        oldQueue.changes.send()
        source.queue = ObservationQueue()
        observer.rebindQueueIfNeeded()
        source.queue.changes.send()
        try await eventually { !batches.isEmpty }
        #expect(batches == [[.queueRebound, .queue]])
        oldQueue.changes.send()
        source.state.send()
        try await eventually { batches.count == 2 }
        #expect(batches[1] == [.state])
    }

    @Test("state invalidation detects an externally replaced queue")
    func stateDetectsReplacement() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        defer { observer.stop() }
        var changes: Set<PlaybackPlayerChange> = []
        observer.start { changes.formUnion($0) }
        source.queue = ObservationQueue()
        source.state.send()
        try await eventually { changes.contains(.queueRebound) }
        source.queue.changes.send()
        try await eventually { changes.contains(.queue) }
        #expect(changes == [.state, .queueRebound, .queue])
    }

    @Test("changes during an awaited delivery trigger one follow-up pass")
    func followsUpWithoutOverlapping() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        defer { observer.stop() }
        var passes = 0
        var active = 0
        var maximumActive = 0
        var continuation: CheckedContinuation<Void, Never>?
        observer.start { _ in
            passes += 1
            active += 1
            maximumActive = max(maximumActive, active)
            if passes == 1 {
                await withCheckedContinuation { continuation = $0 }
            }
            active -= 1
        }
        source.queue.changes.send()
        try await eventually { continuation != nil }
        for _ in 0..<20 { source.state.send() }
        // Wait for the main-queue publisher deliveries before releasing the pass.
        await nextMainQueueTurn()
        #expect(passes == 1)
        continuation?.resume()
        continuation = nil
        try await eventually { passes == 2 }
        #expect(maximumActive == 1)
    }

    @Test("stop discards queued callbacks and restart installs one subscription")
    func cancellationAndRestart() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        defer { observer.stop() }
        var oldCalls = 0
        var newCalls = 0
        observer.start { _ in oldCalls += 1 }
        source.queue.changes.send()
        observer.stop()
        observer.start { _ in newCalls += 1 }
        observer.start { _ in Issue.record("must not replace the active handler") }
        source.state.send()
        try await eventually { newCalls == 1 }
        #expect(oldCalls == 0)
    }

    @Test("cancellation during delivery drops pending work")
    func cancellationDuringDelivery() async throws {
        let source = ObservationSource()
        let observer = source.makeObserver()
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        observer.start { _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
        }
        source.queue.changes.send()
        try await eventually { continuation != nil }
        source.state.send()
        await nextMainQueueTurn()
        observer.stop()
        continuation?.resume()
        await nextMainQueueTurn()
        #expect(calls == 1)
    }
}

@MainActor
private final class ObservationQueue {
    let changes = PassthroughSubject<Void, Never>()
}

@MainActor
private final class ObservationSource {
    var queue = ObservationQueue()
    let state = PassthroughSubject<Void, Never>()
    var value = 0

    func makeObserver() -> PlaybackPlayerObservation {
        PlaybackPlayerObservation(
            queueSource: { [self] in .init(identity: queue, changes: queue.changes.eraseToAnyPublisher()) },
            stateChanges: state.eraseToAnyPublisher()
        )
    }
}

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(predicate())
}

private func nextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
