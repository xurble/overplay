//
//  OverplayApp.swift
//  Overplay
//
//  Created by Gareth Simpson on 14/05/2026.
//

import SwiftUI
import SwiftData

@main
struct OverplayApp: App {
    private static var cloudKitContainerIdentifier: String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "OverplayCloudKitContainerIdentifier") as? String,
              !identifier.isEmpty else {
            preconditionFailure("Missing OverplayCloudKitContainerIdentifier Info.plist value.")
        }

        return identifier
    }

    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            OverplaySettings.self,
            TrackedTrack.self,
            PlaybackEvent.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self,
            SettingsRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(Self.cloudKitContainerIdentifier)
        )
        modelContainer = try! ModelContainer(for: schema, configurations: [configuration])
        try? LegacyModelMigration.migrate(in: modelContainer.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
