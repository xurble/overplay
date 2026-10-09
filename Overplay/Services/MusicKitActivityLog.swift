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
    /// calls worth reading one by one. Large enough to hold a listening
    /// session's entry changes and the failure that ended it (#84).
    static let defaultMaximumEvents = 1_000
    /// Minutes of tallies retained — long enough to cover a listening
    /// session leading up to a failure.
    static let defaultRetainedMinutes = 240
    /// Each launch also writes every event, high-frequency ones included, to
    /// its own file, so the session that failed survives the relaunch that
    /// recovers it (#84). Ten covers a day or two of launches, background
    /// wakes included.
    static let defaultMaximumLaunchLogs = 10
    /// A launch's file past this size keeps its newest half, so ten files
    /// stay under about 50 MB.
    static let defaultMaximumLaunchLogBytes = 5_000_000

    /// The surface issuing the command currently being recorded.
    ///
    /// Ambient rather than a parameter because the player wrapper does the
    /// recording and has no view of who asked. A task-local rather than
    /// shared state because this log is written from several isolation
    /// domains at once — the 1 Hz playback tick, the artwork actor, sync —
    /// and a shared stack would attribute a background call to whichever
    /// command happened to be in flight, then pop the wrong entry when they
    /// overlapped. Task-locals scope to the task tree and are inherited by
    /// child tasks, which is exactly the semantics wanted.
    @TaskLocal static var currentOrigin: MusicKitActivityOrigin?

    private struct Storage {
        var snapshot = MusicKitActivitySnapshot()
        var didLoad = false
        var isDirty = false
        var lastPrunedMinute: Int?
        var persistTask: Task<Void, Never>?
        /// Events not yet appended to this launch's file.
        var pendingLaunchEvents: [MusicKitActivityEvent] = []
        /// Created on the first write, so a launch that records nothing
        /// leaves no file and pushes no older log out.
        var launchLogURL: URL?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "MusicKitActivity"
    )
    private let state = Mutex(Storage())
    /// Launch-file writes come from the debounce task, from flushes on the
    /// main thread and from sharing. Appends, trims and deletes are done one
    /// at a time, so lines are never torn, lost or split across two files.
    private let launchLogIO = Mutex(())
    private let fileURL: URL?
    private let launchLogDirectory: URL?
    private let launchStartedAt: Date
    private let maximumLaunchLogs: Int
    private let maximumLaunchLogBytes: Int
    private let maximumEvents: Int
    private let retainedMinutes: Int
    private let persistDelay: Duration
    private let now: @Sendable () -> Date

    init(
        fileURL: URL? = MusicKitActivityLog.defaultFileURL(),
        maximumEvents: Int = MusicKitActivityLog.defaultMaximumEvents,
        retainedMinutes: Int = MusicKitActivityLog.defaultRetainedMinutes,
        persistDelay: Duration = .seconds(5),
        maximumLaunchLogs: Int = MusicKitActivityLog.defaultMaximumLaunchLogs,
        maximumLaunchLogBytes: Int = MusicKitActivityLog.defaultMaximumLaunchLogBytes,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        launchLogDirectory = fileURL.map(Self.launchLogDirectory(besides:))
        launchStartedAt = now()
        self.maximumLaunchLogs = maximumLaunchLogs
        self.maximumLaunchLogBytes = maximumLaunchLogBytes
        self.maximumEvents = maximumEvents
        self.retainedMinutes = retainedMinutes
        self.persistDelay = persistDelay
        self.now = now
    }

    /// Attributes everything recorded inside `body` to `origin`.
    func withOrigin<T>(_ origin: MusicKitActivityOrigin, _ body: () async -> T) async -> T {
        await Self.$currentOrigin.withValue(origin) { await body() }
    }

    /// Synchronous variant, for command paths that never suspend.
    func withOrigin<T>(_ origin: MusicKitActivityOrigin, _ body: () throws -> T) rethrows -> T {
        try Self.$currentOrigin.withValue(origin) { try body() }
    }

    static func defaultFileURL() -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root
            .appendingPathComponent("Overplay", isDirectory: true)
            .appendingPathComponent("musickit-activity.json")
    }

    /// One file per launch, in a folder beside the snapshot.
    static func launchLogDirectory(besides fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("ActivityLogs", isDirectory: true)
    }

    /// The snapshot and every launch's log, oldest launch first, for sharing.
    func shareableFiles() -> [URL] {
        flush()
        let snapshot = fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return [snapshot].compactMap { $0 } + launchLogs()
    }

    func launchLogs() -> [URL] {
        guard let launchLogDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: launchLogDirectory, includingPropertiesForKeys: nil
              ) else { return [] }
        // Names start with the launch time, so name order is launch order.
        return files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
            origin: Self.currentOrigin,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorDescription: nsError?.localizedDescription,
            errorDetail: error.map(MusicKitActivityEvent.detail(of:))
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
            storage.pendingLaunchEvents = []
            storage.launchLogURL = nil
        }
        launchLogIO.withLock { _ in
            for url in launchLogs() { try? FileManager.default.removeItem(at: url) }
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
            || (event.operation.category == .performance && (event.durationMilliseconds ?? 0) >= 100)

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

            if let duration = event.durationMilliseconds,
               let index = storage.snapshot.tallies.lastIndex(where: {
                   $0.minute == minute && $0.operation == event.operation
               }) {
                storage.snapshot.tallies[index].timedCount = (storage.snapshot.tallies[index].timedCount ?? 0) + 1
                storage.snapshot.tallies[index].totalDurationMilliseconds = (storage.snapshot.tallies[index].totalDurationMilliseconds ?? 0) + duration
                storage.snapshot.tallies[index].maximumDurationMilliseconds = max(storage.snapshot.tallies[index].maximumDurationMilliseconds ?? 0, duration)
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
            if launchLogDirectory != nil {
                storage.pendingLaunchEvents.append(event)
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
        persistLaunchLog()
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

    /// Appends pending events to this launch's file, one JSON event per
    /// line. The first write creates it and removes the oldest launches'
    /// files past the limit; past the size limit it keeps its newest half.
    private func persistLaunchLog() {
        guard let launchLogDirectory else { return }
        launchLogIO.withLock { _ in appendPendingLaunchEvents(in: launchLogDirectory) }
    }

    private func appendPendingLaunchEvents(in launchLogDirectory: URL) {
        let pending: (events: [MusicKitActivityEvent], url: URL?) = state.withLock { storage in
            defer { storage.pendingLaunchEvents = [] }
            return (storage.pendingLaunchEvents, storage.launchLogURL)
        }
        guard !pending.events.isEmpty else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for event in pending.events {
                data.append(try encoder.encode(event))
                data.append(0x0A)
            }
            let url = try pending.url ?? createLaunchLog(in: launchLogDirectory)
            let handle = try FileHandle(forWritingTo: url)
            let size: UInt64
            do {
                defer { try? handle.close() }
                size = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            if Int(size) + data.count > maximumLaunchLogBytes {
                try trimLaunchLog(at: url)
            }
        } catch {
            // Diagnostics must never affect playback. The unified log still
            // holds these events.
        }
    }

    private func createLaunchLog(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.launchLogName(startedAt: launchStartedAt))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        state.withLock { $0.launchLogURL = url }
        for old in launchLogs().filter({ $0 != url }).dropLast(maximumLaunchLogs - 1) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }

    /// Keeps the newest half of the file, cut at a line boundary.
    private func trimLaunchLog(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let cut = data.index(data.startIndex, offsetBy: data.count / 2)
        guard let newline = data[cut...].firstIndex(of: 0x0A) else { return }
        try Data(data[data.index(after: newline)...]).write(to: url, options: [.atomic])
    }

    static func launchLogName(startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        let suffix = UUID().uuidString.prefix(4)
        return "launch-\(formatter.string(from: startedAt))-\(suffix).jsonl"
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
        // The unified log is the sysdiagnose artifact, which is the kind of
        // log that motivated recording origin at all.
        let via = event.origin?.rawValue ?? "-"

        if event.didFail {
            logger.error(
                """
                op=\(operation, privacy: .public) outcome=failed dur=\(duration, privacy: .public) \
                size=\(magnitude, privacy: .public) notes=\(notes, privacy: .public) \
                via=\(via, privacy: .public) domain=\(event.errorDomain ?? "nil", privacy: .public) \
                code=\(event.errorCode ?? 0, privacy: .public) \
                error=\(event.errorDescription ?? "nil", privacy: .public) \
                detail=\(event.detail ?? "-", privacy: .public) \
                chain=\(event.errorDetail ?? "-", privacy: .public)
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
                via=\(via, privacy: .public) detail=\(event.detail ?? "-", privacy: .public)
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
