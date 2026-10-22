import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("First-run setup")
struct SetupViewModelTests {
    struct Harness {
        var container: ModelContainer
        var restoration: LibraryRestorationService
        var dependencies: SetupViewModel.Dependencies
        var createdBox: Box<(name: String, source: String?)>
        var syncedBox: Box<String>
        var created: [(name: String, source: String?)] { createdBox.values }
        var synced: [String] { syncedBox.values }
    }

    final class Box<Value> { var values: [Value] = [] }

    func harness(playlists: [AppleMusicPlaylist] = []) async throws -> Harness {
        let container = try OverplayTestSupport.makeModelContainer()
        let restoration = LibraryRestorationService(defaults: UserDefaults(suiteName: "SetupViewModelTests.\(UUID())")!)
        await #expect(throws: LibraryRestorationService.RestorationError.setupNeeded) {
            try await restoration.prepare(in: container.mainContext, cloudEnabled: false, hasLegacyStore: false,
                                          locallyRebuiltID: nil, attempts: 1)
        }
        let created = Box<(name: String, source: String?)>()
        let synced = Box<String>()
        let dependencies = SetupViewModel.Dependencies { context in
            guard !restoration.isReady else { return }
            try restoration.createLibrary(in: context, hasLegacyStore: false)
        } fetchLibraryPlaylists: {
            playlists
        } createManagedOneTruePlaylist: { name, source, context in
            created.values.append((name, source))
            let record = PlaylistRecord(musicPlaylistID: "p.overplay", name: name, role: .oneTruePlaylist, writePolicy: .managed)
            context.insert(record)
            try context.save()
            return record
        } reconcileSelection: { _, _ in
        } syncPlaylist: { playlist, _ in
            synced.values.append(playlist.musicPlaylistID)
        }
        return Harness(container: container, restoration: restoration, dependencies: dependencies,
                       createdBox: created, syncedBox: synced)
    }

    @Test("TikTok and Shazam playlists are suggested first, never the One True Playlist")
    func suggestions() {
        let model = SetupViewModel()
        model.playlists = [
            AppleMusicPlaylist(id: "a", name: "Road Trip"),
            AppleMusicPlaylist(id: "b", name: "TikTok Songs"),
            AppleMusicPlaylist(id: "c", name: "My Shazam Tracks"),
            AppleMusicPlaylist(id: "d", name: "Tik Tok Hits"),
        ]
        #expect(model.suggestedSources.map(\.id) == ["b", "c", "d"])
        #expect(model.otherSources.map(\.id) == ["a"])
    }

    @Test("swiping through creates nothing; the first choice creates the library")
    func libraryIsCreatedByTheFirstChoice() async throws {
        let harness = try await harness(playlists: [AppleMusicPlaylist(id: "p.tiktok", name: "TikTok Songs")])
        let context = harness.container.mainContext
        let model = SetupViewModel()
        await model.loadPlaylists(dependencies: harness.dependencies)
        #expect(model.playlists.count == 1)
        #expect(!harness.restoration.isReady)
        #expect(try LibraryRestorationService.isEmpty(in: context))

        model.setTriageSource(model.playlists[0], isOn: true, context: context, dependencies: harness.dependencies)
        #expect(harness.restoration.isReady)
        #expect(model.triageSourceIDs == ["p.tiktok"])
        let source = try #require(try PlaylistRepository.playlist(musicPlaylistID: "p.tiktok", in: context))
        #expect(source.role == .triageSource && source.isActive)

        model.setTriageSource(model.playlists[0], isOn: false, context: context, dependencies: harness.dependencies)
        #expect(model.triageSourceIDs.isEmpty)
        #expect(!source.isActive)
    }

    @Test("copying makes a new managed Overplay playlist the One True Playlist")
    func copyCreatesManagedOverplay() async throws {
        let harness = try await harness()
        let context = harness.container.mainContext
        let model = SetupViewModel()
        let source = AppleMusicPlaylist(id: "p.favourites", name: "Favourites", trackCount: 40)
        await model.createOneTruePlaylist(copying: source, context: context, dependencies: harness.dependencies)

        #expect(harness.created.map(\.name) == ["Overplay"])
        #expect(harness.created.map(\.source) == ["p.favourites"])
        #expect(model.hasOneTruePlaylist && model.copiedFrom == "Favourites")
        let settings = try SettingsRepository.settings(in: context)
        #expect(settings.selectedPlaylistID == "p.overplay")
        let otp = try #require(try PlaylistRepository.playlist(musicPlaylistID: "p.overplay", in: context))
        #expect(otp.role == .oneTruePlaylist && otp.writePolicy == .managed)
        // A second tap cannot make a second playlist.
        await model.createOneTruePlaylist(copying: nil, context: context, dependencies: harness.dependencies)
        #expect(harness.created.count == 1)
        // The library opens on the next launch without iCloud.
        let restart = LibraryRestorationService(defaults: UserDefaults(suiteName: "SetupViewModelTests.\(UUID())")!)
        try await restart.prepare(in: context, cloudEnabled: false, hasLegacyStore: false, locallyRebuiltID: nil, attempts: 1)
        #expect(restart.isReady)
    }

    @Test("finishing creates the library if nothing was chosen and syncs chosen sources")
    func finish() async throws {
        let skipped = try await harness()
        #expect(SetupViewModel().finish(context: skipped.container.mainContext, dependencies: skipped.dependencies))
        #expect(skipped.restoration.isReady)
        #expect(skipped.synced.isEmpty)

        let chosen = try await harness()
        let model = SetupViewModel()
        model.setTriageSource(AppleMusicPlaylist(id: "p.shazam", name: "My Shazam Tracks"), isOn: true,
                              context: chosen.container.mainContext, dependencies: chosen.dependencies)
        #expect(model.finish(context: chosen.container.mainContext, dependencies: chosen.dependencies))
        let deadline = ContinuousClock.now + .seconds(2)
        while chosen.synced.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chosen.synced == ["p.shazam"])
    }

    @Test("the One True Playlist and Triage cards each need a choice before moving on")
    func lastTwoCardsNeedAChoice() async throws {
        let harness = try await harness(playlists: [AppleMusicPlaylist(id: "p.tiktok", name: "TikTok Songs")])
        let context = harness.container.mainContext
        let model = SetupViewModel()
        #expect(model.reachablePages.last == .oneTruePlaylist)
        #expect(!model.isDecided(.oneTruePlaylist))
        #expect(SetupPage.allCases.filter { $0 != .oneTruePlaylist && $0 != .triage }.allSatisfy(model.isDecided))

        await model.createOneTruePlaylist(copying: nil, context: context, dependencies: harness.dependencies)
        #expect(model.isDecided(.oneTruePlaylist))
        #expect(model.reachablePages.last == .triage)
        #expect(!model.isDecided(.triage))

        // Choosing a source decides Triage; clearing it again undoes that.
        let tiktok = AppleMusicPlaylist(id: "p.tiktok", name: "TikTok Songs")
        model.setTriageSource(tiktok, isOn: true, context: context, dependencies: harness.dependencies)
        #expect(model.reachablePages == SetupPage.allCases)
        model.setTriageSource(tiktok, isOn: false, context: context, dependencies: harness.dependencies)
        #expect(model.reachablePages.last == .triage)

        // So does choosing to add sources later.
        model.skipTriage()
        #expect(model.isDecided(.triage))
        #expect(model.reachablePages == SetupPage.allCases)
    }
}
