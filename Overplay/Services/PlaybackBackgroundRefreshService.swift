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

    private init() {}

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
            Task { @MainActor in
                Self.shared.handle(task: task)
            }
        }
    }

    private func handle(task: BGAppRefreshTask) {
        task.expirationHandler = {
            TrackMetadataDiagnostics.log("background refresh expired before completing")
        }

        let runtime = AppRuntime.shared
        guard let context = runtime.makeModelContext() else {
            TrackMetadataDiagnostics.log("background refresh woke before the model container was ready")
            task.setTaskCompleted(success: false)
            return
        }

        let result = PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: runtime.playbackController,
            context: context
        )
        TrackMetadataDiagnostics.log(
            "background refresh wake counted=\(result.countedLocalTrackIDs.count) nextTarget=\(result.nextWakeTarget.map { $0.formatted(date: .omitted, time: .standard) } ?? "nil")"
        )
        scheduleNextWake(at: result.nextWakeTarget)
        task.setTaskCompleted(success: true)
    }

    /// Submits the single pending refresh request. A nil target (nothing
    /// playing, unknown duration) submits nothing — with no playback there
    /// is nothing to reconcile, and the scene-phase hooks re-arm whenever
    /// playback state changes again.
    func scheduleNextWake(at earliestBeginDate: Date?) {
        guard let earliestBeginDate else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
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
