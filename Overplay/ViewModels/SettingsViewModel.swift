import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SettingsViewModel {
    struct Dependencies {
        var saveSettings: (OverplaySettings, ModelContext) throws -> Void
        var resetStats: (ModelContext) throws -> Void
        var nukeDatabase: (ModelContext) throws -> Void
        var clearPlaybackStateAfterDatabaseReset: () -> Void
        var runMusicKitDiagnostics: (OverplaySettings, ModelContext) async -> String
        var loadMusicKitActivityReport: () -> MusicKitActivityReport.Summary
        var resetMusicKitActivityLog: () -> Void
        var rebuildOneTruePlaylist: (ModelContext) async throws -> OneTruePlaylistRebuildService.Result = { _ in
            throw OneTruePlaylistRebuildService.RebuildError.notOnThisDevice
        }

        static func live(playbackController: PlaybackController) -> Self {
            Self(
                saveSettings: { settings, context in
                    try SettingsRepository.save(settings, in: context)
                },
                resetStats: { context in
                    try playbackController.resetAllLocalStats(context: context)
                },
                nukeDatabase: { context in
                    _ = try DatabaseResetService.nukeDatabase(in: context)
                },
                clearPlaybackStateAfterDatabaseReset: {
                    playbackController.clearLocalStateAfterDatabaseReset()
                },
                runMusicKitDiagnostics: { settings, context in
                    await MusicKitDiagnosticsService().run(settings: settings, context: context)
                },
                loadMusicKitActivityReport: {
                    // The shared log file is then current with the report.
                    MusicKitActivityLog.shared.flush()
                    return MusicKitDiagnosticsService().activityReport
                },
                resetMusicKitActivityLog: {
                    MusicKitActivityLog.shared.reset()
                },
                rebuildOneTruePlaylist: { context in
                    try await playbackController.rebuildOneTruePlaylist(context: context)
                }
            )
        }
    }

    var didNukeDatabase = false
    var isRebuildingPlaylist = false
    var isRunningMusicKitDiagnostics = false
    var musicKitDiagnosticsReport: String?
    var musicKitActivityReport: MusicKitActivityReport.Summary?
    var message: String?

    func saveIfNeeded(
        settings: OverplaySettings,
        context: ModelContext,
        dependencies: Dependencies
    ) {
        guard !didNukeDatabase else { return }
        try? dependencies.saveSettings(settings, context)
    }

    func resetStats(
        context: ModelContext,
        dependencies: Dependencies
    ) -> Bool {
        do {
            try dependencies.resetStats(context)
            message = "Local stats reset."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func nukeDatabase(
        context: ModelContext,
        dependencies: Dependencies
    ) -> Bool {
        do {
            try dependencies.nukeDatabase(context)
            didNukeDatabase = true
            dependencies.clearPlaybackStateAfterDatabaseReset()
            message = "Database nuked."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func rebuildOneTruePlaylist(context: ModelContext, dependencies: Dependencies) async {
        isRebuildingPlaylist = true
        defer { isRebuildingPlaylist = false }
        do {
            let result = try await dependencies.rebuildOneTruePlaylist(context)
            message = Self.rebuildMessage(result)
        } catch {
            message = error.localizedDescription
        }
    }

    static func rebuildMessage(_ result: OneTruePlaylistRebuildService.Result) -> String {
        var message = "Rebuilt “\(result.name)” in Apple Music with \(result.addedCount) songs. Delete the older “\(result.name)” playlist in the Music app."
        if result.skippedCount > 0 {
            message += " \(result.skippedCount) songs couldn’t be added from this device; they stay in Overplay."
        }
        return message
    }

    func runMusicKitDiagnostics(
        settings: OverplaySettings,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        isRunningMusicKitDiagnostics = true
        defer { isRunningMusicKitDiagnostics = false }

        musicKitDiagnosticsReport = await dependencies.runMusicKitDiagnostics(settings, context)
        refreshMusicKitActivityReport(dependencies: dependencies)
    }

    /// Reads the recorded Apple Music call activity. Makes no Apple Music
    /// calls of its own, so it is safe to run on appearance and to refresh
    /// repeatedly while investigating.
    func refreshMusicKitActivityReport(dependencies: Dependencies) {
        musicKitActivityReport = dependencies.loadMusicKitActivityReport()
    }

    func resetMusicKitActivityLog(dependencies: Dependencies) {
        dependencies.resetMusicKitActivityLog()
        refreshMusicKitActivityReport(dependencies: dependencies)
        message = "Apple Music call activity cleared."
    }
}
