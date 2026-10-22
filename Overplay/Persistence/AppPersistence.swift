import Foundation
import SwiftData

#if OVERPLAY_DEVELOPMENT && !DEBUG
#error("Overplay's developer database is only available in debug builds.")
#endif

#if OVERPLAY_FIRST_RUN && !DEBUG
#error("Overplay's first-run database is only available in debug builds.")
#endif

/// All playback surfaces receive this container through AppRuntime.
enum AppPersistence {
    enum ConfigurationError: Error {
        case developmentRequiresSeparateApp
        case developmentAppRequiresDevelopmentBuild
        case missingCloudKitContainerIdentifier
    }

    /// The simulator has no Apple Music library and must never touch the
    /// owner's iCloud data: the app there uses a separate local store, seeded
    /// with a sample library when empty (`SimulatorDemoLibrary`).
    static let simulatorConfiguration = ModelConfiguration(
        "OverplaySimulator",
        schema: schema,
        groupContainer: .none,
        cloudKitDatabase: .none
    )

    /// UI tests launch the simulator build with this argument: a fresh
    /// in-memory sample library each launch, never the simulator's copy.
    static let uiTestingArgument = "-OverplayUITesting"

    static let uiTestingConfiguration = ModelConfiguration(
        "OverplayUITests",
        schema: schema,
        isStoredInMemoryOnly: true,
        groupContainer: .none,
        cloudKitDatabase: .none
    )

    /// A first-run build (`OVERPLAY_FIRST_RUN`) keeps the everyday app
    /// identifier, and with it CarPlay, but starts from an empty local store
    /// of its own. Its device-local state is kept apart as well, so the
    /// everyday build's restoration receipt and playback intent survive it.
    static var isFirstRunBuild: Bool {
        #if DEBUG && OVERPLAY_FIRST_RUN
        true
        #else
        false
        #endif
    }

    /// Device-local preferences that describe the store's library.
    static var libraryDefaults: UserDefaults {
        isFirstRunBuild ? UserDefaults(suiteName: "farm.poplar.Overplay.firstRun") ?? .standard : .standard
    }

    static var playbackIntentURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            isFirstRunBuild ? "Overplay/FirstRun/PlaybackIntent.json" : "Overplay/PlaybackIntent.json"
        )
    }

    /// A first-run build launched with this argument starts from nothing:
    /// its store, preferences and playback intent are removed first.
    static let firstRunResetArgument = "-OverplayFirstRunReset"

    static func resetFirstRunIfRequested() {
        guard isFirstRunBuild, ProcessInfo.processInfo.arguments.contains(firstRunResetArgument) else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appendingPathComponent("OverplayFirstRun.store\(suffix)"))
        }
        try? FileManager.default.removeItem(at: playbackIntentURL)
        UserDefaults.standard.removePersistentDomain(forName: "farm.poplar.Overplay.firstRun")
    }

    static var cloudEnabled: Bool {
        #if OVERPLAY_DEVELOPMENT || OVERPLAY_FIRST_RUN || targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    static var schema: Schema {
        Schema([
            OverplaySettings.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            ApplePlayCountRecord.self,
            HistoryEvent.self,
            ListenEvent.self,
            RecentCollectionRecord.self
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

        #if DEBUG && OVERPLAY_FIRST_RUN
        return ModelConfiguration(
            "OverplayFirstRun",
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        #elseif DEBUG && OVERPLAY_DEVELOPMENT
        // Fail closed if local build settings accidentally reuse the everyday
        // app identifier. The separate sandbox also isolates UserDefaults,
        // playback restoration, onboarding history, and diagnostic files.
        guard bundleIdentifier?.hasSuffix(".dev") == true else {
            throw ConfigurationError.developmentRequiresSeparateApp
        }
        return ModelConfiguration(
            "OverplayDevelopmentV2",
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
            "OverplayLibraryV2",
            schema: schema,
            groupContainer: .none,
            cloudKitDatabase: .private(cloudKitContainerIdentifier)
        )
        #endif
    }
}
