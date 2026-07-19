//
//  OverplayApp.swift
//  Overplay
//
//  Created by Gareth Simpson on 14/05/2026.
//

import Foundation
import SwiftData
import SwiftUI

@main
@MainActor
struct OverplayApp: App {
    private static var schema: Schema {
        Schema([
            OverplaySettings.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self
        ])
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static var cloudKitContainerIdentifier: String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "OverplayCloudKitContainerIdentifier") as? String,
              !identifier.isEmpty else {
            preconditionFailure("Missing OverplayCloudKitContainerIdentifier Info.plist value.")
        }

        return identifier
    }

    private static func makeModelContainer() throws -> ModelContainer {
        try StartupProfiler.measure("SwiftData model container") {
            let schema = Self.schema
            let configuration: ModelConfiguration

            if isRunningTests {
                configuration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            } else {
                configuration = ModelConfiguration(
                    schema: schema,
                    cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
                )
            }

            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    private let modelContainer: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            modelContainer = try Self.makeModelContainer()
            AppRuntime.shared.configure(modelContainer: modelContainer)
        } catch {
            fatalError("Could not create Overplay model container: \(error)")
        }

        if !Self.isRunningTests {
            PlaybackBackgroundRefreshService.shared.register()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(runtime: .shared)
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            Task { @MainActor in
                await handleScenePhaseChange(newPhase)
            }
        }
    }

    /// Suspended-playback reconciliation runs at both edges of a
    /// suspension: entering the background records the exact baseline
    /// waypoint and arms the aimed refresh wake; returning to the
    /// foreground reconciles whatever played while suspended before the
    /// monitor's staleness rules would discard it.
    private func handleScenePhaseChange(_ phase: ScenePhase) async {
        guard !Self.isRunningTests else { return }
        guard phase == .background || phase == .active else { return }
        guard let context = AppRuntime.shared.makeModelContext() else { return }

        if phase == .background {
            let target = PlaybackReconciliationService.nextWakeTarget(
                playbackController: AppRuntime.shared.playbackController,
                context: context
            )
            PlaybackBackgroundRefreshService.shared.scheduleNextWake(at: target)
        }

        _ = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: AppRuntime.shared.playbackController,
            context: context
        )
    }
}
