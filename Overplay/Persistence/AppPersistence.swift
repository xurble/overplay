import Foundation
import SwiftData

#if OVERPLAY_DEVELOPMENT && !DEBUG
#error("Overplay's developer database is only available in debug builds.")
#endif

/// All playback surfaces receive this container through AppRuntime.
enum AppPersistence {
    enum ConfigurationError: Error {
        case developmentRequiresSeparateApp
        case developmentAppRequiresDevelopmentBuild
        case missingCloudKitContainerIdentifier
    }

    static var schema: Schema {
        Schema([
            OverplaySettings.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            HistoryEvent.self
        ])
    }

    static func configuration(
        isRunningTests: Bool,
        bundleIdentifier: String?,
        cloudKitContainerIdentifier: String?
    ) throws -> ModelConfiguration {
        if isRunningTests {
            return ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        }

        #if DEBUG && OVERPLAY_DEVELOPMENT
        // Fail closed if local build settings accidentally reuse the everyday
        // app identifier. The separate sandbox also isolates UserDefaults,
        // playback restoration, onboarding history, and diagnostic files.
        guard bundleIdentifier?.hasSuffix(".dev") == true else {
            throw ConfigurationError.developmentRequiresSeparateApp
        }
        return ModelConfiguration(
            "OverplayDevelopment",
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        #else
        // A development app must never fall through to personal CloudKit data
        // if someone removes its flag or changes its build configuration.
        guard bundleIdentifier?.hasSuffix(".dev") != true else {
            throw ConfigurationError.developmentAppRequiresDevelopmentBuild
        }
        guard let cloudKitContainerIdentifier, !cloudKitContainerIdentifier.isEmpty else {
            throw ConfigurationError.missingCloudKitContainerIdentifier
        }
        return ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
        #endif
    }
}
