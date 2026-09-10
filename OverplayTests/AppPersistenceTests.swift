import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct AppPersistenceTests {
    @Test func testHostAlwaysUsesAnEphemeralLocalStore() throws {
        let configuration = try AppPersistence.configuration(
            isRunningTests: true,
            bundleIdentifier: nil,
            cloudKitContainerIdentifier: "iCloud.personal"
        )
        #expect(configuration.isStoredInMemoryOnly)
        #expect(configuration.cloudKitContainerIdentifier == nil)
        #expect(configuration.groupAppContainerIdentifier == nil)

        let first = try ModelContainer(for: AppPersistence.schema, configurations: [configuration])
        first.mainContext.insert(OverplaySettings())
        try first.mainContext.save()
        let second = try ModelContainer(for: AppPersistence.schema, configurations: [configuration])
        #expect(try second.mainContext.fetchCount(FetchDescriptor<OverplaySettings>()) == 0)
        #expect(try first.mainContext.fetchCount(FetchDescriptor<OverplaySettings>()) == 1)
    }

    #if DEBUG && OVERPLAY_DEVELOPMENT
    @Test func developmentIgnoresPersonalCloudKitAndUsesItsOwnPersistentStore() throws {
        let configuration = try AppPersistence.configuration(
            isRunningTests: false,
            bundleIdentifier: "com.example.Overplay.dev",
            cloudKitContainerIdentifier: "iCloud.personal"
        )
        #expect(!configuration.isStoredInMemoryOnly)
        #expect(configuration.cloudKitContainerIdentifier == nil)
        #expect(configuration.groupAppContainerIdentifier == nil)
        #expect(configuration.name == "OverplayDevelopment")
        #expect(configuration.url != ModelConfiguration(schema: AppPersistence.schema).url)
    }

    @Test(arguments: [nil, "com.example.Overplay", "com.example.Overplay.dev.other"] as [String?])
    func developmentRejectsAnEverydayAppIdentifier(identifier: String?) {
        #expect(throws: AppPersistence.ConfigurationError.developmentRequiresSeparateApp) {
            try AppPersistence.configuration(
                isRunningTests: false,
                bundleIdentifier: identifier,
                cloudKitContainerIdentifier: "iCloud.personal"
            )
        }
    }
    #else
    @Test func everydayBuildRetainsPersonalCloudKitConfiguration() throws {
        let configuration = try AppPersistence.configuration(
            isRunningTests: false,
            bundleIdentifier: "com.example.Overplay",
            cloudKitContainerIdentifier: "iCloud.personal"
        )
        #expect(!configuration.isStoredInMemoryOnly)
        #expect(configuration.cloudKitContainerIdentifier == "iCloud.personal")
        #expect(configuration.url == ModelConfiguration(schema: AppPersistence.schema).url)
    }

    @Test func everydayBuildCannotOpenTheDevelopmentApp() {
        #expect(throws: AppPersistence.ConfigurationError.developmentAppRequiresDevelopmentBuild) {
            try AppPersistence.configuration(
                isRunningTests: false,
                bundleIdentifier: "com.example.Overplay.dev",
                cloudKitContainerIdentifier: "iCloud.personal"
            )
        }
    }

    @Test(arguments: [nil, ""] as [String?])
    func everydayBuildRequiresExplicitCloudKitContainer(identifier: String?) {
        #expect(throws: AppPersistence.ConfigurationError.missingCloudKitContainerIdentifier) {
            try AppPersistence.configuration(
                isRunningTests: false,
                bundleIdentifier: "com.example.Overplay",
                cloudKitContainerIdentifier: identifier
            )
        }
    }
    #endif
}
