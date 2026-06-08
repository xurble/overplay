import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Settings view model")
struct SettingsViewModelTests {
    @Test("save is skipped after database nuke")
    func saveIsSkippedAfterDatabaseNuke() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings()
        let viewModel = SettingsViewModel()
        viewModel.didNukeDatabase = true
        var saveCallCount = 0
        let dependencies = makeDependencies(
            saveSettings: { _, _ in
                saveCallCount += 1
            }
        )

        viewModel.saveIfNeeded(settings: settings, context: context, dependencies: dependencies)

        #expect(saveCallCount == 0)
    }

    @Test("reset stats reports success")
    func resetStatsReportsSuccess() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = SettingsViewModel()
        var resetCallCount = 0
        let dependencies = makeDependencies(
            resetStats: { _ in
                resetCallCount += 1
            }
        )

        let shouldDismiss = viewModel.resetStats(context: context, dependencies: dependencies)

        #expect(shouldDismiss)
        #expect(resetCallCount == 1)
        #expect(viewModel.message == "Local stats reset.")
    }

    @Test("nuke database clears playback state and disables later save")
    func nukeDatabaseClearsPlaybackStateAndDisablesLaterSave() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = SettingsViewModel()
        var nukeCallCount = 0
        var clearCallCount = 0
        let dependencies = makeDependencies(
            nukeDatabase: { _ in
                nukeCallCount += 1
            },
            clearPlaybackStateAfterDatabaseReset: {
                clearCallCount += 1
            }
        )

        let shouldDismiss = viewModel.nukeDatabase(context: context, dependencies: dependencies)

        #expect(shouldDismiss)
        #expect(nukeCallCount == 1)
        #expect(clearCallCount == 1)
        #expect(viewModel.didNukeDatabase)
        #expect(viewModel.message == "Database nuked.")
    }

    @Test("action failure reports error and stays visible")
    func actionFailureReportsErrorAndStaysVisible() throws {
        struct Failure: LocalizedError {
            var errorDescription: String? { "Reset failed." }
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let viewModel = SettingsViewModel()
        let dependencies = makeDependencies(
            resetStats: { _ in
                throw Failure()
            }
        )

        let shouldDismiss = viewModel.resetStats(context: context, dependencies: dependencies)

        #expect(!shouldDismiss)
        #expect(viewModel.message == "Reset failed.")
    }

    @Test("diagnostics stores report and clears progress state")
    func diagnosticsStoresReportAndClearsProgressState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = OverplaySettings()
        let viewModel = SettingsViewModel()
        let dependencies = makeDependencies(
            runMusicKitDiagnostics: { _, _ in
                "Diagnostics report"
            }
        )

        await viewModel.runMusicKitDiagnostics(settings: settings, context: context, dependencies: dependencies)

        #expect(!viewModel.isRunningMusicKitDiagnostics)
        #expect(viewModel.musicKitDiagnosticsReport == "Diagnostics report")
    }

    private func makeDependencies(
        saveSettings: @escaping (OverplaySettings, ModelContext) throws -> Void = { _, _ in },
        resetStats: @escaping (ModelContext) throws -> Void = { _ in },
        nukeDatabase: @escaping (ModelContext) throws -> Void = { _ in },
        clearPlaybackStateAfterDatabaseReset: @escaping () -> Void = { },
        runMusicKitDiagnostics: @escaping (OverplaySettings, ModelContext) async -> String = { _, _ in "" }
    ) -> SettingsViewModel.Dependencies {
        SettingsViewModel.Dependencies(
            saveSettings: saveSettings,
            resetStats: resetStats,
            nukeDatabase: nukeDatabase,
            clearPlaybackStateAfterDatabaseReset: clearPlaybackStateAfterDatabaseReset,
            runMusicKitDiagnostics: runMusicKitDiagnostics
        )
    }
}
