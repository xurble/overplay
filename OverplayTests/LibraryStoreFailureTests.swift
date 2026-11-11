import Foundation
import SwiftData
import Testing
@testable import Overplay

/// `STORE-001`: a store that cannot be opened is reported and left alone.
@MainActor
@Suite("Library store failure")
struct LibraryStoreFailureTests {
    private struct OpenFailure: Error {}

    private func makeFailedRuntime() -> AppRuntime {
        let runtime = AppRuntime()
        #expect(runtime.openLibraryStore { throw OpenFailure() } == nil)
        return runtime
    }

    @Test func aFailedStoreIsReportedAndOffersNoLibrary() async {
        let runtime = makeFailedRuntime()

        #expect(runtime.libraryStoreFailure?.contains("OpenFailure") == true)
        #expect(runtime.mainModelContext == nil)
        #expect(runtime.makeModelContext() == nil)
        // Siri stops here: no startup, no playback and no curation.
        #expect(await runtime.prepareForBackgroundAction(timeout: .zero) == nil)
        #expect(!runtime.startupViewModel.hasStartedAuthorizedServices)
        #expect(runtime.backgroundActionRefusal == VoiceActions.storeUnavailableMessage)
    }

    @Test func aStoreThatOpensConfiguresTheRuntime() throws {
        let runtime = AppRuntime()
        let container = try OverplayTestSupport.makeModelContainer()

        #expect(runtime.openLibraryStore { container } === container)
        #expect(runtime.libraryStoreFailure == nil)
        #expect(runtime.mainModelContext != nil)
        #expect(runtime.backgroundActionRefusal == VoiceActions.notReadyMessage)
    }

    /// A real SwiftData failure on a real file: SQLite refuses it, and the
    /// bytes are still there afterwards.
    @Test func aCorruptStoreFileIsNotTouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Broken.store")
        let bytes = Data(repeating: 0x41, count: 8192)
        try bytes.write(to: url)

        let runtime = AppRuntime()
        let container = runtime.openLibraryStore {
            let configuration = ModelConfiguration("Broken", schema: AppPersistence.schema, url: url, cloudKitDatabase: .none)
            return try ModelContainer(for: AppPersistence.schema, configurations: [configuration])
        }

        #expect(container == nil)
        #expect(runtime.libraryStoreFailure != nil)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Broken.store"])
    }
}
