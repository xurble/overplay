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
struct OverplayApp: App {
    private static var schema: Schema {
        Schema([
            OverplaySettings.self,
            TrackedTrack.self,
            PlaybackEvent.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self,
            SettingsRecord.self
        ])
    }

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private static var cloudKitContainerIdentifier: String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "OverplayCloudKitContainerIdentifier") as? String,
              !identifier.isEmpty else {
            preconditionFailure("Missing OverplayCloudKitContainerIdentifier Info.plist value.")
        }

        return identifier
    }

    private static func makeModelContainer() throws -> ModelContainer {
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

    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try Self.makeModelContainer()
        } catch {
            fatalError("Could not create Overplay model container: \(error)")
        }

        try? LegacyModelMigration.migrate(in: modelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
