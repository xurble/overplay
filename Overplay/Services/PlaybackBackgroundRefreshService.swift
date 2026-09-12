import BackgroundTasks
import Foundation

/// Requests and handles BGAppRefresh wakes for suspended-playback
/// reconciliation. iOS grants at most one pending request per identifier
/// and only ever delivers late, so each wake is aimed at the moment a
/// single snapshot carries maximum proof — the playthrough-threshold
/// crossing of the current track (see PlaybackReconciliationPolicy).
@MainActor
final class PlaybackBackgroundRefreshService {
    static let shared = PlaybackBackgroundRefreshService()

    static var taskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "Overplay") + ".playback-refresh"
    }

    private var isRegistered = false

    static let fallbackWakeInterval: TimeInterval = 15 * 60
    private let submit: (BGAppRefreshTaskRequest) throws -> Void
    private let now: () -> Date

    init(
        submit: @escaping (BGAppRefreshTaskRequest) throws -> Void = { try BGTaskScheduler.shared.submit($0) },
        now: @escaping () -> Date = { .now }
    ) {
        self.submit = submit
        self.now = now
    }

    /// Must run before the app finishes launching (OverplayApp.init).
    func register() {
        guard !isRegistered else { return }
        isRegistered = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let operation = Task { @MainActor in
                await Self.shared.handle(task: task)
            }
            task.expirationHandler = {
                operation.cancel()
                TrackMetadataDiagnostics.log("background refresh expired before completing")
            }
        }
    }

    private func handle(task: BGAppRefreshTask) async {
        let success = await performRefresh {
            let runtime = AppRuntime.shared
            guard let context = runtime.makeModelContext() else {
                TrackMetadataDiagnostics.log("background refresh woke before the model container was ready")
                return nil
            }
            return await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
                playbackController: runtime.playbackController,
                context: context
            )
        }
        task.setTaskCompleted(success: success)
    }

    /// Re-arm before the first suspension point. Expiration, a missing model
    /// container, and an unobservable queue cannot silently end the wake chain.
    func performRefresh(
        operation: () async -> PlaybackReconciliationService.Result?
    ) async -> Bool {
        scheduleNextWake(at: nil)
        guard !Task.isCancelled, let result = await operation(), !Task.isCancelled else {
            return false
        }
        if let target = result.nextWakeTarget {
            scheduleNextWake(at: target)
        }
        return true
    }

    /// iOS may decline a request or never grant it. Always attempt a bounded
    /// fallback when there is no useful track target; foreground recovery does
    /// not depend on a grant.
    func scheduleNextWake(at earliestBeginDate: Date?) {
        let earliestBeginDate = earliestBeginDate ?? now().addingTimeInterval(Self.fallbackWakeInterval)

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try submit(request)
            TrackMetadataDiagnostics.log(
                "background refresh requested for \(earliestBeginDate.formatted(date: .omitted, time: .standard))"
            )
        } catch {
            // Expected on simulators and with Background App Refresh
            // disabled; reconciliation still runs on every foregrounding.
            TrackMetadataDiagnostics.log("background refresh request failed: \(error.localizedDescription)")
        }
    }
}
