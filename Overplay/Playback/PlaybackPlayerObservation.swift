import Combine
import Foundation

nonisolated enum PlaybackPlayerChange: String, Hashable, Sendable {
    case queue
    case state
    case queueRebound
}

/// MusicKit publishes invalidations before its values change. Hop to the main
/// queue before reading, then coalesce bursts without losing changes delivered
/// while the async consumer is suspended. The injected publishers also let tests
/// exercise queue replacement without live MusicKit.
@MainActor
final class PlaybackPlayerObservation {
    struct QueueSource {
        var identity: AnyObject
        var changes: AnyPublisher<Void, Never>
    }

    private let queueSource: () -> QueueSource
    private let stateChanges: AnyPublisher<Void, Never>
    private var queueIdentity: AnyObject?
    private var queueSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?
    private var handler: (@MainActor (Set<PlaybackPlayerChange>) async -> Void)?
    private var pending: Set<PlaybackPlayerChange> = []
    private var deliveryTask: Task<Void, Never>?
    private var generation = 0

    init(queueSource: @escaping () -> QueueSource, stateChanges: AnyPublisher<Void, Never>) {
        self.queueSource = queueSource
        self.stateChanges = stateChanges
    }

    func start(_ handler: @escaping @MainActor (Set<PlaybackPlayerChange>) async -> Void) {
        guard self.handler == nil else { return }
        self.handler = handler
        let generation = generation
        stateSubscription = stateChanges.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.invalidate(.state)
            }
        }
        rebindQueueIfNeeded()
    }

    /// Called after our own queue writes and on every shared reconciliation.
    /// MusicKit exposes no publisher for the player's queue property itself;
    /// state events and the existing timer also detect external replacement.
    func rebindQueueIfNeeded() {
        guard handler != nil else { return }
        let source = queueSource()
        guard queueIdentity !== source.identity else { return }
        let wasBound = queueIdentity != nil
        queueSubscription?.cancel()
        queueIdentity = source.identity
        let generation = generation
        let identity = ObjectIdentifier(source.identity)
        queueSubscription = source.changes.receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation,
                      self.queueIdentity.map(ObjectIdentifier.init) == identity else { return }
                self.invalidate(.queue)
            }
        }
        if wasBound {
            MusicKitActivityLog.shared.record(.playbackQueueObservationRebound)
            enqueue(.queueRebound)
        }
    }

    func stop() {
        generation += 1
        queueSubscription?.cancel()
        stateSubscription?.cancel()
        queueSubscription = nil
        stateSubscription = nil
        queueIdentity = nil
        handler = nil
        pending.removeAll()
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func invalidate(_ change: PlaybackPlayerChange) {
        MusicKitActivityLog.shared.record(
            change == .queue ? .playbackQueueInvalidation : .playbackStateInvalidation
        )
        rebindQueueIfNeeded()
        enqueue(change)
    }

    private func enqueue(_ change: PlaybackPlayerChange) {
        pending.insert(change)
        guard deliveryTask == nil else {
            MusicKitActivityLog.shared.record(.playbackObservationCoalesced)
            return
        }
        let generation = generation
        deliveryTask = Task { [weak self] in
            // Let other invalidations already enqueued on the main queue join
            // this batch. Never read state inside objectWillChange itself.
            await Task.yield()
            while let self, !Task.isCancelled, self.generation == generation {
                guard !self.pending.isEmpty, let handler = self.handler else {
                    self.deliveryTask = nil
                    return
                }
                let changes = self.pending
                self.pending.removeAll()
                await handler(changes)
            }
        }
    }
}
