import Foundation
import OSLog
import Synchronization

/// Records every Overplay call into Apple Music's out-of-process services.
///
/// The Apple Music stack Overplay drives (`MusicKit`, `MusicLibrary`,
/// `ApplicationMusicPlayer`, `MPNowPlayingInfoCenter`,
/// `MPRemoteCommandCenter`) lives in other processes shared with the Music
/// app itself, so an app that calls it too often, too fast, or with invalid
/// arguments degrades Apple Music system-wide rather than just failing
/// locally. Nothing in those APIs reports a rate limit or a quota, so the
/// only way to see abuse is to measure our own call pattern.
///
/// Two outputs, deliberately:
///
/// - Minute-bucketed tallies plus a bounded list of notable calls, held in
///   memory and snapshotted to disk. This is what the in-app diagnostics
///   screen reads, and the disk copy is why it survives the app relaunch
///   that follows the device reboot used to recover Apple Music.
/// - One `Logger` line per call under the `MusicKitActivity` category, which
///   lands in the unified log. That copy survives app death and reboot and
///   can be pulled off the device in a sysdiagnose taken while Apple Music
///   is broken.
///
/// Writes come from every isolation domain, including synchronous
/// non-isolated code on the 1 Hz playback tick, so state is held under a
/// `Mutex` rather than in an actor.
nonisolated final class MusicKitActivityLog: Sendable {
    static let shared = MusicKitActivityLog()

    /// Individually listed calls retained. High-frequency operations are
    /// tallied instead of listed, so this holds a long narrative of the
    /// calls worth reading one by one.
    static let defaultMaximumEvents = 250
    /// Minutes of tallies retained — long enough to cover a listening
    /// session leading up to a failure.
    static let defaultRetainedMinutes = 240

    private struct Storage {
        var snapshot = MusicKitActivitySnapshot()
        var didLoad = false
        var isDirty = false
        var lastPrunedMinute: Int?
        var persistTask: Task<Void, Never>?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "MusicKitActivity"
    )
    private let state = Mutex(Storage())
    private let fileURL: URL?
    private let maximumEvents: Int
    private let retainedMinutes: Int
    private let persistDelay: Duration
    private let now: @Sendable () -> Date

    init(
        fileURL: URL? = MusicKitActivityLog.defaultFileURL(),
        maximumEvents: Int = MusicKitActivityLog.defaultMaximumEvents,
        retainedMinutes: Int = MusicKitActivityLog.defaultRetainedMinutes,
        persistDelay: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        self.maximumEvents = maximumEvents
        self.retainedMinutes = retainedMinutes
        self.persistDelay = persistDelay
        self.now = now
    }

    static func defaultFileURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root
            .appendingPathComponent("Overplay", isDirectory: true)
            .appendingPathComponent("musickit-activity.json")
    }

    // MARK: - Recording

    func record(
        _ operation: MusicKitActivityOperation,
        startedAt: Date? = nil,
        duration: Duration? = nil,
        magnitude: Double? = nil,
        detail: String? = nil,
        notes: [MusicKitActivityNote] = [],
        error: Error? = nil
    ) {
        let startedAt = startedAt ?? now()
        let nsError = error.map { $0 as NSError }
        let event = MusicKitActivityEvent(
            operation: operation,
            startedAt: startedAt,
            durationMilliseconds: duration.map(Self.milliseconds(of:)),
            magnitude: magnitude,
            detail: detail,
            notes: notes,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription
        )
        append(event)
        emitToUnifiedLog(event)
    }

    /// Times an async Apple Music call and records its outcome.
    @discardableResult
    func measure<T>(
        _ operation: MusicKitActivityOperation,
        magnitude: Double? = nil,
        detail: String? = nil,
        notes: [MusicKitActivityNote] = [],
        resultMagnitude: ((T) -> Double?)? = nil,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let startedAt = now()
        let started = ContinuousClock.now
        do {
            let value = try await body()
            record(
                operation,
                startedAt: startedAt,
                duration: started.duration(to: .now),
                magnitude: resultMagnitude?(value) ?? magnitude,
                detail: detail,
                notes: notes
            )
            return value
        } catch {
            record(
                operation,
                startedAt: startedAt,
                duration: started.duration(to: .now),
                magnitude: magnitude,
                detail: detail,
                notes: notes,
                error: error
            )
            throw error
        }
    }

    /// Times a synchronous Apple Music call and records its outcome.
    @discardableResult
    func measure<T>(
        _ operation: MusicKitActivityOperation,
        magnitude: Double? = nil,
        detail: String? = nil,
        notes: [MusicKitActivityNote] = [],
        _ body: () throws -> T
    ) rethrows -> T {
        let startedAt = now()
        let started = ContinuousClock.now
        do {
            let value = try body()
            record(
                operation,
                startedAt: startedAt,
                duration: started.duration(to: .now),
                magnitude: magnitude,
                detail: detail,
                notes: notes
            )
            return value
        } catch {
            record(
                operation,
                startedAt: startedAt,
                duration: started.duration(to: .now),
                magnitude: magnitude,
                detail: detail,
                notes: notes,
                error: error
            )
            throw error
        }
    }

    // MARK: - Reading

    func snapshot() -> MusicKitActivitySnapshot {
        loadIfNeeded()
        return state.withLock { storage in
            var snapshot = storage.snapshot
            snapshot.tallies.sort { left, right in
                left.minute == right.minute
                    ? left.operation.rawValue < right.operation.rawValue
                    : left.minute < right.minute
            }
            return snapshot
        }
    }

    func report(now referenceDate: Date? = nil) -> MusicKitActivityReport.Summary {
        MusicKitActivityReport.summary(for: snapshot(), now: referenceDate ?? now())
    }

    func reset() {
        state.withLock { storage in
            storage.snapshot = MusicKitActivitySnapshot(observationStartedAt: now())
            storage.didLoad = true
            storage.isDirty = true
        }
        persistNow()
    }

    /// Writes the snapshot immediately. Called when the app leaves the
    /// foreground, so an incident that ends in a device reboot still has the
    /// last few seconds of activity on disk.
    func flush() {
        persistNow()
    }

    // MARK: - Storage

    private func append(_ event: MusicKitActivityEvent) {
        loadIfNeeded()
        let minute = MusicKitActivityTally.minuteIndex(for: event.startedAt)
        let oldestRetainedMinute = minute - retainedMinutes
        let maximumEvents = maximumEvents
        let shouldList = !event.operation.isHighFrequency || event.didFail || !event.notes.isEmpty

        state.withLock { storage in
            if storage.snapshot.observationStartedAt == nil {
                storage.snapshot.observationStartedAt = event.startedAt
            }

            // Searching from the end: the current minute's tallies were
            // appended most recently, and this runs on the 1 Hz playback tick.
            if let index = storage.snapshot.tallies.lastIndex(where: {
                $0.minute == minute && $0.operation == event.operation
            }) {
                storage.snapshot.tallies[index].count += 1
                if event.didFail {
                    storage.snapshot.tallies[index].failureCount += 1
                }
                if let magnitude = event.magnitude {
                    storage.snapshot.tallies[index].maximumMagnitude = max(
                        storage.snapshot.tallies[index].maximumMagnitude ?? magnitude,
                        magnitude
                    )
                }
            } else {
                storage.snapshot.tallies.append(
                    MusicKitActivityTally(
                        minute: minute,
                        operation: event.operation,
                        count: 1,
                        failureCount: event.didFail ? 1 : 0,
                        maximumMagnitude: event.magnitude
                    )
                )
            }

            // Pruning is an O(n) pass, so do it once per minute rather than
            // once per recorded call.
            if storage.lastPrunedMinute != minute {
                storage.lastPrunedMinute = minute
                storage.snapshot.tallies.removeAll { $0.minute < oldestRetainedMinute }
            }

            if shouldList {
                storage.snapshot.events.append(event)
                if storage.snapshot.events.count > maximumEvents {
                    storage.snapshot.events.removeFirst(storage.snapshot.events.count - maximumEvents)
                }
            }

            storage.isDirty = true
            schedulePersist(&storage)
        }
    }

    /// Debounced so a burst of calls costs one file write, matching the
    /// artwork cache manifest's approach. The data is disposable
    /// diagnostics, so losing the last few seconds on a crash is fine.
    private func schedulePersist(_ storage: inout Storage) {
        guard storage.persistTask == nil, fileURL != nil else { return }
        let persistDelay = persistDelay
        storage.persistTask = Task<Void, Never>.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: persistDelay)
            guard let self else { return }
            self.state.withLock { $0.persistTask = nil }
            self.persistNow()
        }
    }

    private func persistNow() {
        guard let fileURL else { return }
        let snapshot: MusicKitActivitySnapshot? = state.withLock { storage in
            guard storage.isDirty else { return nil }
            storage.isDirty = false
            return storage.snapshot
        }
        guard let snapshot else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
        } catch {
            // Diagnostics must never affect playback. The in-memory copy and
            // the unified log both still hold this activity.
            state.withLock { $0.isDirty = true }
        }
    }

    private func loadIfNeeded() {
        let shouldLoad = state.withLock { storage -> Bool in
            guard !storage.didLoad else { return false }
            storage.didLoad = true
            return true
        }
        guard shouldLoad, let fileURL, let data = try? Data(contentsOf: fileURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let restored = try? decoder.decode(MusicKitActivitySnapshot.self, from: data) else { return }

        let oldestRetainedMinute = MusicKitActivityTally.minuteIndex(for: now()) - retainedMinutes
        state.withLock { storage in
            var restored = restored
            restored.tallies.removeAll { $0.minute < oldestRetainedMinute }
            // A record made before the file finished loading must survive.
            restored.tallies.append(contentsOf: storage.snapshot.tallies)
            restored.events.append(contentsOf: storage.snapshot.events)
            if restored.events.count > maximumEvents {
                restored.events.removeFirst(restored.events.count - maximumEvents)
            }
            restored.observationStartedAt = restored.observationStartedAt
                ?? storage.snapshot.observationStartedAt
            storage.snapshot = restored
        }
    }

    // MARK: - Unified log

    private func emitToUnifiedLog(_ event: MusicKitActivityEvent) {
        let operation = event.operation.rawValue
        let duration = event.durationMilliseconds.map { String(format: "%.0fms", $0) } ?? "-"
        let magnitude = event.magnitude.map { String(format: "%.0f", $0) } ?? "-"
        let notes = event.notes.isEmpty ? "-" : event.notes.map(\.rawValue).joined(separator: ",")

        if event.didFail {
            logger.error(
                """
                op=\(operation, privacy: .public) outcome=failed dur=\(duration, privacy: .public) \
                size=\(magnitude, privacy: .public) notes=\(notes, privacy: .public) \
                domain=\(event.errorDomain ?? "nil", privacy: .public) \
                code=\(event.errorCode ?? 0, privacy: .public) \
                error=\(event.errorDescription ?? "nil", privacy: .public) \
                detail=\(event.detail ?? "-", privacy: .public)
                """
            )
        } else if event.operation.isHighFrequency {
            // Exact per-minute counts already cover these, so keep them out
            // of the unified log's in-memory ring where they would evict the
            // individually interesting lines.
            logger.debug(
                """
                op=\(operation, privacy: .public) outcome=ok dur=\(duration, privacy: .public) \
                size=\(magnitude, privacy: .public)
                """
            )
        } else {
            logger.info(
                """
                op=\(operation, privacy: .public) outcome=ok dur=\(duration, privacy: .public) \
                size=\(magnitude, privacy: .public) notes=\(notes, privacy: .public) \
                detail=\(event.detail ?? "-", privacy: .public)
                """
            )
        }
    }

    private static func milliseconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
