import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// CarPlay's adapter routing (TST-1): each action resolves to the shared
/// controller entry point the app and Siri use (`SURFACE-001`, AGENTS.md
/// "Behavioral parity is mandatory").
///
/// Each comparison arranges two identical fixtures, performs the CarPlay
/// action on one and the app's call on the other, and compares what the player
/// was told and the shared state afterwards. The commands are also pinned, so
/// the two cannot agree on the wrong thing. App call sites inside a SwiftUI
/// view body cannot be invoked here; those comparisons make the same call the
/// view makes, and name the view.
///
/// Tests marked with a finding from `docs/CODE_REVIEW_2026-11-11.md` pin a
/// known divergence as it stands today. Fixing that finding should change them.
@MainActor
@Suite("CarPlay action routing", .serialized, .timeLimit(.minutes(1)))
struct CarPlayActionRoutingTests {
    /// What a surface's action did, from after the arrangement.
    struct Observed: Equatable {
        var commands: [String]
        var submittedTitles: [[String]]
        var submittedStartIndices: [Int]
        var currentTitle: String?
        var isPlaying: Bool
        var shuffleEnabled: Bool
        var repeatAllEnabled: Bool
        var context: PlaylistPlaybackContext?
        var collectionKey: String?
        var failure: String?
        var status: String?
    }

    struct Comparison {
        var carPlay: Observed
        var app: Observed
        var followUp: CarPlayActionFollowUp
    }

    private typealias Arrange = @MainActor (PlaybackFixture) async throws -> Void

    private func observe(_ fixture: PlaybackFixture, commandsBefore: Int, submissionsBefore: Int) -> Observed {
        Observed(
            commands: Array(fixture.player.commands.dropFirst(commandsBefore)),
            submittedTitles: Array(fixture.player.submittedTitles.dropFirst(submissionsBefore)),
            submittedStartIndices: Array(fixture.player.submittedStartIndices.dropFirst(submissionsBefore)),
            currentTitle: fixture.controller.currentTrack?.title,
            isPlaying: fixture.controller.isPlaying,
            shuffleEnabled: fixture.controller.shuffleEnabled,
            repeatAllEnabled: fixture.controller.repeatAllEnabled,
            context: fixture.controller.currentPlaylistContext,
            collectionKey: fixture.controller.playingCollectionGroupKey,
            failure: fixture.controller.playbackFailure?.message,
            status: fixture.controller.statusMessage
        )
    }

    private func perform(_ action: CarPlayAction, on fixture: PlaybackFixture) async -> CarPlayActionFollowUp {
        await action.perform(controller: fixture.controller, context: fixture.context)
    }

    private func compare(
        role: PlaylistRole = .oneTruePlaylist,
        trackCount: Int = 3,
        arrange: Arrange = { _ in },
        carPlay: @MainActor (PlaybackFixture) throws -> CarPlayAction,
        app: @MainActor (PlaybackFixture) async throws -> Void
    ) async throws -> Comparison {
        let carPlayFixture = try PlaybackFixture(trackCount: trackCount, role: role)
        defer { carPlayFixture.cleanUp() }
        let appFixture = try PlaybackFixture(trackCount: trackCount, role: role)
        defer { appFixture.cleanUp() }
        try await arrange(carPlayFixture)
        try await arrange(appFixture)

        let carPlayCommands = carPlayFixture.player.commands.count
        let carPlaySubmissions = carPlayFixture.player.submitCount
        let followUp = await perform(try carPlay(carPlayFixture), on: carPlayFixture)

        let appCommands = appFixture.player.commands.count
        let appSubmissions = appFixture.player.submitCount
        try await app(appFixture)

        return Comparison(
            carPlay: observe(carPlayFixture, commandsBefore: carPlayCommands, submissionsBefore: carPlaySubmissions),
            app: observe(appFixture, commandsBefore: appCommands, submissionsBefore: appSubmissions),
            followUp: followUp
        )
    }

    // MARK: - App entry points

    /// `PlaylistManagementViewModel.swift:42`, the app's row selection.
    private func appSelectsRow(_ index: Int, scope: PlaylistPlaybackScope = .active, in fixture: PlaybackFixture) async throws {
        try await PlaylistManagementViewModel().play(
            fixture.item(index), track: fixture.tracks[index], playlist: fixture.playlist, settings: fixture.settings,
            scope: scope, context: fixture.context, dependencies: .live(playbackController: fixture.controller)
        )
    }

    /// `PlaylistManagementViewModel.swift:45`, the app's Shuffle and Play.
    private func appShuffles(_ fixture: PlaybackFixture) async {
        await PlaylistManagementViewModel().playPlaylist(
            playlist: fixture.playlist, settings: fixture.settings, context: fixture.context,
            dependencies: .live(playbackController: fixture.controller)
        )
    }

    /// `PlaybackControlsView.swift:78`, the app's primary button.
    private func appPressesPrimary(_ fixture: PlaybackFixture) async {
        await fixture.controller.performPrimaryPlaybackAction(settings: fixture.settings, context: fixture.context)
    }

    private func select(_ index: Int, in fixture: PlaybackFixture, scope: PlaylistPlaybackScope = .active) -> CarPlayAction {
        .selectTrack(trackID: fixture.tracks[index].id, in: fixture.playlist, scope: scope)
    }

    private func playing(_ index: Int = 0, in fixture: PlaybackFixture) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func paused(_ index: Int = 0, in fixture: PlaybackFixture) async {
        await playing(index, in: fixture)
        fixture.controller.pause()
    }

    /// Playback that has failed to start, so the shared failure is showing.
    private func failed(_ fixture: PlaybackFixture) async {
        fixture.player.prepareFailuresRemaining = 1
        await playing(in: fixture)
    }

    // MARK: - Track rows

    @Test func trackRowStartsThePlaylistAtThatTrackLikeTheApp() async throws {
        let result = try await compare(
            carPlay: { select(1, in: $0) },
            app: { try await appSelectsRow(1, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.contains("submit"))
        #expect(result.carPlay.submittedStartIndices == [1])
        #expect(result.carPlay.currentTitle == "Song 1")
        #expect(!result.carPlay.shuffleEnabled)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func trackRowInThePlayingQueueIsSelectedInPlaceLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await playing(0, in: $0) },
            carPlay: { select(2, in: $0) },
            app: { try await appSelectsRow(2, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["select", "play"])
        #expect(result.carPlay.currentTitle == "Song 2")
        #expect(result.followUp == .nowPlaying)
    }

    @Test func trackRowInThePausedQueueIsSelectedInPlaceLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await paused(0, in: $0) },
            carPlay: { select(2, in: $0) },
            app: { try await appSelectsRow(2, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["select", "play"])
        #expect(result.carPlay.isPlaying)
    }

    @Test func thePausedCurrentTrackResumesWithoutRestartingLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await paused(1, in: $0) },
            carPlay: { select(1, in: $0) },
            app: { try await appSelectsRow(1, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["play"])
        #expect(result.carPlay.currentTitle == "Song 1")
        #expect(result.followUp == .nowPlaying)
    }

    @Test func thePlayingCurrentTrackIsLeftAloneLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await playing(1, in: $0) },
            carPlay: { select(1, in: $0) },
            app: { try await appSelectsRow(1, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.isEmpty)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func trackRowKeepsTheListsScopeLikeTheApp() async throws {
        var retiredContext: PlaylistPlaybackContext?
        let result = try await compare(
            role: .triageBucket,
            arrange: { fixture in
                try fixture.item(2).evictedAt = .now
                try fixture.context.save()
                retiredContext = fixture.playlist.playbackContext(.retired)
            },
            carPlay: { select(2, in: $0, scope: .retired) },
            app: { try await appSelectsRow(2, scope: .retired, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.context == retiredContext)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func aFailedTrackStartLeavesTheSharedFailureToAlert() async throws {
        let result = try await compare(
            arrange: { $0.player.prepareFailuresRemaining = 1 },
            carPlay: { select(1, in: $0) },
            app: { try await appSelectsRow(1, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure != nil)
        #expect(result.followUp == .nothing)
    }

    @Test func aTrackThatHasGoneRefreshesTheListsAndCallsNothing() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let unknown = await perform(.selectTrack(trackID: UUID(), in: fixture.playlist, scope: .active), on: fixture)
        let missing = await perform(.selectTrack(trackID: nil, in: fixture.playlist, scope: .active), on: fixture)

        #expect(unknown == .staleLists)
        #expect(missing == .staleLists)
        #expect(!unknown.reachedController)
        #expect(fixture.player.commands.isEmpty)
    }

    // MARK: - Shuffle and Play row

    @Test func shuffleRowStartsShuffledLikeTheApp() async throws {
        let result = try await compare(
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await appShuffles($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.contains("submit"))
        #expect(result.carPlay.commands.contains("shuffle=songs"))
        #expect(result.carPlay.shuffleEnabled)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func shuffleRowStartsShuffledLikeSiri() async throws {
        let result = try await compare(
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { _ = await VoiceActions.play(.oneTruePlaylist, controller: $0.controller, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
    }

    @Test func shuffleRowOnThePausedUnshuffledPlaylistShufflesAndResumesLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await paused(1, in: $0) },
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await appShuffles($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["shuffle=songs", "play"])
        #expect(result.carPlay.submittedTitles.isEmpty)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func shuffleRowOnThePlayingPlaylistOnlyTurnsShuffleOnLikeTheApp() async throws {
        let result = try await compare(
            arrange: { await playing(1, in: $0) },
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await appShuffles($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["shuffle=songs"])
        #expect(result.carPlay.currentTitle == "Song 1")
    }

    /// What the dashboard's Play button runs (`DashboardView.play`).
    private func dashboardPlays(_ fixture: PlaybackFixture) async {
        await DashboardView.play(fixture.playlist, settings: fixture.settings, controller: fixture.controller,
                                 context: fixture.context)
    }

    /// `PLAY-020` on the main screen: a paused, unshuffled One True Playlist
    /// gets shuffle turned on and plays, as it does from CarPlay and Siri.
    @Test func dashboardPlayOnThePausedUnshuffledPlaylistShufflesAndResumesLikeCarPlay() async throws {
        let result = try await compare(
            arrange: { await paused(1, in: $0) },
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await dashboardPlays($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.app.commands == ["shuffle=songs", "play"])
        #expect(result.app.shuffleEnabled)
        #expect(result.app.submittedTitles.isEmpty)
    }

    @Test func dashboardPlayOfAnotherPlaylistStartsItShuffledLikeCarPlay() async throws {
        let result = try await compare(
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await dashboardPlays($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.app.commands.contains("submit"))
        #expect(result.app.commands.contains("shuffle=songs"))
    }

    @Test func shuffleRowThatStartsNothingReportsIt() async throws {
        let result = try await compare(
            trackCount: 0,
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await appShuffles($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.context == nil)
        #expect(result.followUp == .playbackFailed)
    }

    @Test func aFailedShuffleStartLeavesTheSharedFailureToAlert() async throws {
        let result = try await compare(
            arrange: { $0.player.prepareFailuresRemaining = 1 },
            carPlay: { .shuffleAndPlay($0.playlist, scope: .active) },
            app: { await appShuffles($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure != nil)
        #expect(result.followUp == .nothing)
    }

    // MARK: - Row tables

    @Test func aPlaylistListsRowsResolveToTheirActions() async throws {
        let shuffled = try PlaybackFixture(); defer { shuffled.cleanUp() }
        let selected = try PlaybackFixture(); defer { selected.cleanUp() }
        func rows(_ fixture: PlaybackFixture) throws -> (rows: [String: CarPlayAction], summaries: [TrackSummaryPresentation]) {
            let summaries = try CarPlayLibrarySnapshot.trackSummaries(forPlaylistID: fixture.playlist.id, scope: .active, in: fixture.context)
            return (CarPlayAction.playlistRows(summaries, in: fixture.playlist, scope: .active), summaries)
        }

        let shuffleRows = try rows(shuffled)
        #expect(Set(shuffleRows.rows.keys) == Set(["shuffle"] + shuffleRows.summaries.map(\.id.uuidString)))
        _ = await perform(try #require(shuffleRows.rows["shuffle"]), on: shuffled)
        #expect(shuffled.controller.shuffleEnabled)

        let selectRows = try rows(selected)
        let row = try #require(selectRows.summaries.first { $0.title == "Song 2" })
        _ = await perform(try #require(selectRows.rows[row.id.uuidString]), on: selected)
        #expect(selected.controller.currentTrack?.title == "Song 2")
        #expect(selected.player.submittedStartIndices == [2])
        #expect(!selected.controller.shuffleEnabled)
    }

    @Test func aPlaylistListOffersOnlyTheRowsItShows() throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let summaries = try CarPlayLibrarySnapshot.trackSummaries(forPlaylistID: fixture.playlist.id, scope: .active, in: fixture.context)

        let rows = CarPlayAction.playlistRows(summaries.prefix(1), in: fixture.playlist, scope: .active)

        #expect(Set(rows.keys) == ["shuffle", summaries[0].id.uuidString])
    }

    @Test func aRecentsListsRowsResolveToTheirActions() async throws {
        let shuffled = try PlaybackFixture(); defer { shuffled.cleanUp() }
        let selected = try PlaybackFixture(); defer { selected.cleanUp() }
        try addRecent(to: shuffled)
        try addRecent(to: selected)
        func rows(_ fixture: PlaybackFixture) throws -> [String: CarPlayAction] {
            CarPlayAction.recentRows(recentID: try recentID(in: fixture), catalogSongIDs: ["alb-1", "alb-2"])
        }

        let shuffleRows = try rows(shuffled)
        #expect(Set(shuffleRows.keys) == ["shuffle", "alb-1", "alb-2"])
        _ = await perform(try #require(shuffleRows["shuffle"]), on: shuffled)
        #expect(shuffled.player.commands.contains("shuffle=songs"))

        _ = await perform(try #require(try rows(selected)["alb-2"]), on: selected)
        #expect(selected.controller.currentTrack?.title == "Album Song 2")
        #expect(selected.player.submittedStartIndices == [1])
        #expect(!selected.controller.shuffleEnabled)
    }

    // MARK: - Transport Play

    @Test func resumeRowOnPausedPlaybackIsPlayLikeTheAppsPrimaryButton() async throws {
        let result = try await compare(
            arrange: { await paused(1, in: $0) },
            carPlay: { _ in .resumeBeforeRestoration },
            app: { await appPressesPrimary($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["play"])
        #expect(result.carPlay.isPlaying)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func tryAgainRecoversLikeTheAppsPrimaryButton() async throws {
        let result = try await compare(
            arrange: { await failed($0) },
            carPlay: { _ in .tryAgainAfterFailure },
            app: { await appPressesPrimary($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.contains("play"))
        #expect(result.carPlay.failure == nil)
        #expect(result.followUp == .nothing)
    }

    @Test func resumeRowDuringAFailureRecoversAndGoesToNowPlaying() async throws {
        let result = try await compare(
            arrange: { await failed($0) },
            carPlay: { _ in .resumeBeforeRestoration },
            app: { await appPressesPrimary($0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure == nil)
        #expect(result.followUp == .nowPlaying)
    }

    @Test func resumeRowThatFailsAgainLeavesTheSharedFailureToAlert() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await failed(fixture)
        fixture.player.prepareFailuresRemaining = 5
        fixture.player.playFailuresRemaining = 5

        let followUp = await perform(.resumeBeforeRestoration, on: fixture)

        #expect(fixture.controller.playbackFailure != nil)
        #expect(followUp == .nothing)
    }

    /// PA-6: CarPlay's Resume row calls `play(context:)` where the app's
    /// primary button calls `performPrimaryPlaybackAction`. With music
    /// playing, the same press plays on in CarPlay and pauses in the app.
    @Test func pinsPA6ResumeWhilePlayingIsPlayWhereTheAppsPrimaryButtonPauses() async throws {
        let result = try await compare(
            arrange: { await playing(1, in: $0) },
            carPlay: { _ in .resumeBeforeRestoration },
            app: { await appPressesPrimary($0) }
        )

        #expect(result.carPlay.commands == ["play"])
        #expect(result.app.commands == ["pause"])
        #expect(result.carPlay.isPlaying)
        #expect(!result.app.isPlaying)
    }

    @Test func nowPlayingShuffleAndRepeatToggleLikeTheApp() async throws {
        let shuffle = try await compare(
            arrange: { await playing(in: $0) },
            carPlay: { _ in .toggleShuffle },
            app: { await $0.controller.toggleShuffle(context: $0.context) } // NowPlayingComponents.swift:390
        )
        let repeatAll = try await compare(
            arrange: { await playing(in: $0) },
            carPlay: { _ in .toggleRepeat },
            app: { await $0.controller.toggleRepeatAll(context: $0.context) } // NowPlayingComponents.swift:396
        )

        #expect(shuffle.carPlay == shuffle.app)
        #expect(shuffle.carPlay.commands == ["shuffle=songs"])
        #expect(shuffle.followUp == .nothing)
        #expect(repeatAll.carPlay == repeatAll.app)
        #expect(repeatAll.carPlay.commands == ["repeat=all"])
        #expect(repeatAll.followUp == .nothing)
    }

    // MARK: - Recents

    @discardableResult
    private func addRecent(to fixture: PlaybackFixture) throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        try RecentCollectionRepository.record(
            PlaybackCollection(kind: .album, catalogID: "album-1", title: "Test Album"),
            songs: [Self.song("alb-1", "Album Song 1"), Self.song("alb-2", "Album Song 2")],
            artworkURLTemplate: nil, in: fixture.context
        )
        return catalog
    }

    private func recentID(in fixture: PlaybackFixture) throws -> UUID {
        try #require(try RecentCollectionRepository.recents(in: fixture.context).first).id
    }

    /// `RecentCollectionView.swift:28`.
    private func appPlaysRecent(startingAt songID: String?, in fixture: PlaybackFixture) async throws {
        let recent = try #require(try RecentCollectionRepository.recents(in: fixture.context).first)
        await fixture.controller.playRecent(recent, startingAt: songID, context: fixture.context)
    }

    @Test func recentsShuffleRowPlaysLikeTheApp() async throws {
        let result = try await compare(
            arrange: { try addRecent(to: $0) },
            carPlay: { .playRecent(id: try recentID(in: $0), startingAt: nil) },
            app: { try await appPlaysRecent(startingAt: nil, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.contains("shuffle=songs"))
        #expect(result.followUp == .nowPlaying)
    }

    @Test func recentsSongRowStartsThereLikeTheApp() async throws {
        let result = try await compare(
            arrange: { try addRecent(to: $0) },
            carPlay: { .playRecent(id: try recentID(in: $0), startingAt: "alb-2") },
            app: { try await appPlaysRecent(startingAt: "alb-2", in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.currentTitle == "Album Song 2")
        #expect(result.carPlay.submittedStartIndices == [1])
        #expect(result.followUp == .nowPlaying)
    }

    @Test func recentsSongRowInThePlayingEntryIsSelectedInPlaceLikeTheApp() async throws {
        let result = try await compare(
            arrange: { fixture in
                try addRecent(to: fixture)
                try await appPlaysRecent(startingAt: "alb-1", in: fixture)
            },
            carPlay: { .playRecent(id: try recentID(in: $0), startingAt: "alb-2") },
            app: { try await appPlaysRecent(startingAt: "alb-2", in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands == ["select", "play"])
        #expect(result.carPlay.currentTitle == "Album Song 2")
    }

    @Test func recentThatCannotBeReachedReportsItLikeTheApp() async throws {
        let result = try await compare(
            arrange: { fixture in try addRecent(to: fixture).failure = PlaybackCollectionError.empty },
            carPlay: { .playRecent(id: try recentID(in: $0), startingAt: nil) },
            app: { try await appPlaysRecent(startingAt: nil, in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.status?.hasPrefix("Couldn't play Test Album") == true)
        #expect(result.followUp == .playbackFailed)
    }

    @Test func aFailedRecentStartLeavesTheSharedFailureToAlert() async throws {
        let result = try await compare(
            arrange: { fixture in
                try addRecent(to: fixture)
                fixture.player.prepareFailuresRemaining = 1
            },
            carPlay: { .playRecent(id: try recentID(in: $0), startingAt: "alb-1") },
            app: { try await appPlaysRecent(startingAt: "alb-1", in: $0) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure != nil)
        #expect(result.followUp == .nothing)
    }

    @Test func aRecentThatHasGoneRefreshesTheListsAndCallsNothing() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let followUp = await perform(.playRecent(id: UUID(), startingAt: nil), on: fixture)

        #expect(followUp == .staleLists)
        #expect(fixture.player.commands.isEmpty)
    }

    // MARK: - Library and Made For You

    private static func song(_ id: String, _ title: String) -> PlaybackCollectionSong {
        PlaybackCollectionSong(catalogID: id, title: title, artistName: "Artist 0")
    }

    private static func entries() throws -> [LibraryBrowser.Entry] {
        try [("alb-1", "Album Song 1"), ("alb-2", "Album Song 2")].map { id, title in
            let song = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "type": "songs",
                "attributes": ["name": title, "artistName": "Artist 0", "albumName": "Album", "genreNames": []]
            ]))
            return LibraryBrowser.Entry(song: Self.song(id, title), track: .song(song))
        }
    }

    private let libraryItem = LibraryBrowser.Item(kind: .album, libraryID: "l.album", title: "Library Album")
    private let mix = MadeForYouLibrary.Item(id: "mix-1", name: "Favourites Mix")

    private func prepareCollections(_ fixture: PlaybackFixture) {
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
    }

    @Test func libraryRowsPlayLikeTheApp() async throws {
        let entries = try Self.entries()
        for start in [nil, "alb-2"] as [String?] {
            let result = try await compare(
                arrange: { prepareCollections($0) },
                carPlay: { _ in .playLibraryItem(libraryItem, entries: entries, startingAt: start) },
                app: { await LibraryBrowser.play(libraryItem, entries: entries, startingAt: start,
                                                 controller: $0.controller, context: $0.context) }
            )

            #expect(result.carPlay == result.app)
            #expect(result.carPlay.collectionKey == libraryItem.collection.groupKey)
            #expect(result.carPlay.commands.contains("shuffle=songs") == (start == nil))
            #expect(result.followUp == .nowPlaying)
        }
    }

    @Test func madeForYouRowsPlayLikeTheApp() async throws {
        let entries = try Self.entries()
        for start in [nil, "alb-2"] as [String?] {
            let result = try await compare(
                arrange: { prepareCollections($0) },
                carPlay: { _ in .playMadeForYou(mix, entries: entries, startingAt: start) },
                app: { await MadeForYouLibrary.play(mix, entries: entries, startingAt: start,
                                                    controller: $0.controller, context: $0.context) }
            )

            #expect(result.carPlay == result.app)
            #expect(result.carPlay.collectionKey == mix.collection.groupKey)
            #expect(result.carPlay.commands.contains("shuffle=songs") == (start == nil))
            #expect(result.followUp == .nowPlaying)
        }
    }

    @Test func aLibraryCollectionThatStartsNothingReportsIt() async throws {
        let result = try await compare(
            arrange: { prepareCollections($0) },
            carPlay: { _ in .playLibraryItem(libraryItem, entries: [], startingAt: nil) },
            app: { await LibraryBrowser.play(libraryItem, entries: [], startingAt: nil,
                                             controller: $0.controller, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.isEmpty)
        #expect(result.followUp == .playbackFailed)
    }

    @Test func aFailedLibraryStartLeavesTheSharedFailureToAlert() async throws {
        let entries = try Self.entries()
        let result = try await compare(
            arrange: { fixture in
                prepareCollections(fixture)
                fixture.player.prepareFailuresRemaining = 1
            },
            carPlay: { _ in .playLibraryItem(libraryItem, entries: entries, startingAt: "alb-1") },
            app: { await LibraryBrowser.play(libraryItem, entries: entries, startingAt: "alb-1",
                                             controller: $0.controller, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure != nil)
        #expect(result.followUp == .nothing)
    }

    // MARK: - Play Album and Play Artist

    @discardableResult
    private func playingWithCatalog(_ fixture: PlaybackFixture) async throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        catalog.contents[.artist] = PlaybackCollectionContents(
            collection: PlaybackCollection(kind: .artistEssentials, catalogID: "artist-1", title: "Artist 0"),
            tracks: [try FakePlaybackCatalog.track(id: "art-1", title: "Artist Song 1")]
        )
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await playing(in: fixture)
        return catalog
    }

    @Test func playAlbumAndPlayArtistStartLikeTheApp() async throws {
        let cases: [(PlaybackCollection.Request, String)] = [(.album, "Song 0"), (.artist, "Artist Song 1")]
        for (request, firstTitle) in cases {
            let result = try await compare(
                arrange: { try await playingWithCatalog($0) },
                carPlay: { _ in .playCurrentCollection(request) },
                app: { await $0.controller.playCurrentCollection(request, context: $0.context) } // NowPlayingComponents.swift:120
            )

            #expect(result.carPlay == result.app)
            #expect(result.carPlay.currentTitle == firstTitle)
            #expect(result.carPlay.submittedStartIndices == [0])
            // Started, the coordinator is already going back to Now Playing.
            #expect(result.followUp == .nothing)
        }
    }

    @Test func aFailedPlayAlbumLookupReportsItLikeTheApp() async throws {
        let result = try await compare(
            arrange: { fixture in try await playingWithCatalog(fixture).failure = PlaybackCollectionError.albumNotFound },
            carPlay: { _ in .playCurrentCollection(.album) },
            app: { await $0.controller.playCurrentCollection(.album, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.submittedTitles.isEmpty)
        #expect(result.carPlay.status != nil)
        #expect(result.followUp == .playbackFailed)
    }

    @Test func aFailedAlbumStartLeavesTheSharedFailureToAlert() async throws {
        let result = try await compare(
            arrange: { fixture in
                try await playingWithCatalog(fixture)
                fixture.player.prepareFailuresRemaining = 1
            },
            carPlay: { _ in .playCurrentCollection(.album) },
            app: { await $0.controller.playCurrentCollection(.album, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.failure != nil)
        #expect(result.followUp == .nothing)
    }

    // MARK: - Promote, Retire and Restore

    @discardableResult
    private func addOneTruePlaylist(to fixture: PlaybackFixture) throws -> PlaylistRecord {
        let otp = PlaylistRecord(musicPlaylistID: "playlist-otp", name: "One True", role: .oneTruePlaylist)
        fixture.context.insert(otp)
        try fixture.context.save()
        return otp
    }

    private func stubAppleMusic(_ fixture: PlaybackFixture) {
        var mutations = PlaylistMutationService(addRemotely: { _, _, _ in })
        mutations.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.playlistMutations = mutations
        fixture.controller.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.remoteMembership.canEditPlaylists = { false }
    }

    private func playingInTriage(_ fixture: PlaybackFixture) async throws {
        try addOneTruePlaylist(to: fixture)
        stubAppleMusic(fixture)
        await playing(in: fixture)
    }

    @Test func promoteMovesTheCurrentSongLikeTheAppAndSiri() async throws {
        let otpIDs = try await curationPlaylists(.promote, role: .triageBucket, arrange: { try await playingInTriage($0) }) { fixture in
            _ = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)
        }

        #expect(otpIDs.carPlay == otpIDs.app)
        #expect(otpIDs.carPlay == "playlist-otp")
        #expect(otpIDs.followUp == .nothing)
        #expect(otpIDs.commands.isEmpty, "Promote keeps the song playing (MUT-004)")
    }

    @Test func retireRetiresTheCurrentSongAndMovesOnLikeTheAppAndSiri() async throws {
        let result = try await compare(
            arrange: { fixture in
                stubAppleMusic(fixture)
                try fixture.item(0).skipCount = 2
                try fixture.context.save()
                await playing(0, in: fixture)
            },
            carPlay: { _ in .retire },
            app: { _ = await VoiceActions.curate(.retire, controller: $0.controller, context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.commands.contains("next"))
        #expect(result.carPlay.currentTitle == "Song 1")
        #expect(result.followUp == .nothing)
    }

    @Test func retireMarksTheCurrentSongRetired() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try fixture.item(0).skipCount = 2
        try fixture.context.save()
        await playing(0, in: fixture)

        _ = await perform(.retire, on: fixture)

        #expect(try fixture.item(0).evictedAt != nil)
    }

    @Test func restoreBringsTheRetiredCurrentSongBackLikeTheApp() async throws {
        let arrange: Arrange = { fixture in
            stubAppleMusic(fixture)
            try fixture.item(0).skipCount = 2
            try fixture.context.save()
            try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired",
                                               context: fixture.context)
            let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
            await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired,
                                                  settings: fixture.settings, context: fixture.context)
        }
        let result = try await compare(
            arrange: arrange,
            carPlay: { _ in .restore },
            app: { _ = $0.controller.restoreCurrent(context: $0.context) } // NowPlayingComponents.swift:413
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.status == "Moved to the Inbox.")
        #expect(result.followUp == .nothing)

        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        try await arrange(fixture)
        _ = await perform(.restore, on: fixture)
        #expect(try fixture.item(0).evictedAt == nil)
    }

    private struct CurationResult {
        var carPlay: String?
        var app: String?
        var followUp: CarPlayActionFollowUp
        var commands: [String]
    }

    /// Where the current song's item ended up on each surface.
    private func curationPlaylists(
        _ action: CarPlayAction, role: PlaylistRole, arrange: Arrange,
        app: @MainActor (PlaybackFixture) async throws -> Void
    ) async throws -> CurationResult {
        func location(_ fixture: PlaybackFixture) throws -> String? {
            let item = try fixture.item(0)
            return try PlaylistRepository.playlist(id: item.playlistID, in: fixture.context)?.musicPlaylistID
        }
        let carPlayFixture = try PlaybackFixture(role: role); defer { carPlayFixture.cleanUp() }
        let appFixture = try PlaybackFixture(role: role); defer { appFixture.cleanUp() }
        try await arrange(carPlayFixture)
        try await arrange(appFixture)
        let commandsBefore = carPlayFixture.player.commands.count

        let followUp = await perform(action, on: carPlayFixture)
        try await app(appFixture)

        return CurationResult(carPlay: try location(carPlayFixture), app: try location(appFixture), followUp: followUp,
                              commands: Array(carPlayFixture.player.commands.dropFirst(commandsBefore)))
    }

    /// A Promote that Apple Music refuses tells the driver what Siri would say.
    @Test func aFailedPromoteIsReportedInCarPlayLikeSiri() async throws {
        let carPlay = try PlaybackFixture(role: .triageBucket); defer { carPlay.cleanUp() }
        let siri = try PlaybackFixture(role: .triageBucket); defer { siri.cleanUp() }
        for fixture in [carPlay, siri] {
            try addOneTruePlaylist(to: fixture)
            fixture.controller.playlistMutations = PlaylistMutationService(addRemotely: { _, _, _ in
                throw PlaylistMutationError.musicItemMissing
            })
            await playing(in: fixture)
        }

        let followUp = await perform(.promote, on: carPlay)
        let outcome = await VoiceActions.curate(.promote, controller: siri.controller, context: siri.context)

        guard case .failed = outcome else {
            Issue.record("Siri should report a failed promote, got \(outcome)")
            return
        }
        #expect(followUp == .trackActionFailed(outcome.message))
        #expect(followUp.reachedController)
    }

    /// As above, with nothing from Overplay to act on, and a false Restore.
    @Test func curationWithNothingPlayingIsReportedInCarPlay() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let promote = await perform(.promote, on: fixture)
        let retire = await perform(.retire, on: fixture)
        let restore = await perform(.restore, on: fixture)

        #expect(promote == .trackActionFailed("Nothing from Overplay is playing."))
        #expect(retire == .trackActionFailed("Nothing from Overplay is playing."))
        #expect(restore == .trackActionFailed("Choose a retired track to restore."))
        #expect(fixture.player.commands.isEmpty)
    }

    @Test func retiringASongAlreadyRetiredIsReportedInCarPlay() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try fixture.item(0).skipCount = 2
        try fixture.context.save()
        try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired",
                                           context: fixture.context)
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired,
                                              settings: fixture.settings, context: fixture.context)

        let followUp = await perform(.retire, on: fixture)

        #expect(followUp == .trackActionFailed("Song 0 is already retired."))
    }

    // MARK: - Add

    /// An album playing, on a song Overplay does not track.
    private func playingUntrackedSong(_ fixture: PlaybackFixture) async throws {
        try await playingWithCatalog(fixture)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()
        #expect(fixture.controller.canAddCurrentToOverplay)
    }

    private func stubCatalogAdds(_ fixture: PlaybackFixture) {
        fixture.controller.addCatalogSongToPlaylist = { _, _, _ in }
    }

    @Test func addToTriageAddsLikeTheApp() async throws {
        let result = try await compare(
            arrange: { try await playingUntrackedSong($0) },
            carPlay: { _ in .addToTriage },
            app: { await $0.controller.addCurrentToTriage(context: $0.context) } // NowPlayingComponents.swift:420
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.status == "Added to the Inbox.")
        #expect(result.followUp == .nothing)
    }

    @Test func addToOneTruePlaylistAddsLikeTheApp() async throws {
        let result = try await compare(
            arrange: { fixture in
                stubCatalogAdds(fixture)
                try await playingUntrackedSong(fixture)
            },
            carPlay: { _ in .addToOneTruePlaylist },
            app: { await $0.controller.addCurrentToOneTruePlaylist(context: $0.context) } // NowPlayingComponents.swift:425
        )

        #expect(result.carPlay == result.app)
        #expect(result.carPlay.status == "Added to the One True Playlist.")
        #expect(result.followUp == .nothing)
    }

    @Test func aFailedAddIsReportedWithTheControllersReason() async throws {
        let result = try await compare(
            arrange: { fixture in
                fixture.controller.addCatalogSongToPlaylist = { _, _, _ in throw PlaylistMutationError.musicItemMissing }
                try await playingUntrackedSong(fixture)
            },
            carPlay: { _ in .addToOneTruePlaylist },
            app: { await $0.controller.addCurrentToOneTruePlaylist(context: $0.context) }
        )

        #expect(result.carPlay == result.app)
        let status = try #require(result.carPlay.status)
        #expect(result.followUp == .couldNotAdd(status))
    }

    /// PA-4: success is inferred from whichever song is current after the
    /// add. If the next song is also untracked, a successful add is reported
    /// as a failure, with the success message as its text.
    @Test func pinsPA4ASuccessfulAddIsReportedAsFailureWhenTheNextSongIsAlsoUntracked() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        try await playingUntrackedSong(fixture)
        var addedSongs: [String] = []
        fixture.controller.addCatalogSongToPlaylist = { songID, _, _ in
            addedSongs.append(songID)
            await fixture.player.externallyAdvance()
        }

        let followUp = await perform(.addToOneTruePlaylist, on: fixture)

        #expect(addedSongs == ["alb-1"])
        #expect(fixture.controller.currentTrack?.title == "Album Song 2")
        #expect(fixture.controller.statusMessage == "Added to the One True Playlist.")
        #expect(followUp == .couldNotAdd("Added to the One True Playlist."))
    }

    // MARK: - Activity attribution

    @Test func actionsThatStartPlaybackAreAttributedToCarPlay() async throws {
        let entries = try Self.entries()
        let cases: [(name: String, arrange: Arrange, action: @MainActor (PlaybackFixture) throws -> CarPlayAction)] = [
            ("track row", { _ in }, { select(1, in: $0) }),
            ("shuffle row", { _ in }, { .shuffleAndPlay($0.playlist, scope: .active) }),
            ("resume row", { await paused(in: $0) }, { _ in .resumeBeforeRestoration }),
            ("try again", { await paused(in: $0) }, { _ in .tryAgainAfterFailure }),
            ("recent", { try addRecent(to: $0) }, { .playRecent(id: try recentID(in: $0), startingAt: "alb-1") }),
            ("library", { prepareCollections($0) }, { _ in .playLibraryItem(libraryItem, entries: entries, startingAt: "alb-1") }),
            ("made for you", { prepareCollections($0) }, { _ in .playMadeForYou(mix, entries: entries, startingAt: "alb-1") }),
            ("play album", { try await playingWithCatalog($0) }, { _ in .playCurrentCollection(.album) })
        ]
        for testCase in cases {
            let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
            try await testCase.arrange(fixture)
            var origins: [MusicKitActivityOrigin?] = []
            fixture.player.onPlay = { origins.append(MusicKitActivityLog.currentOrigin) }

            _ = await perform(try testCase.action(fixture), on: fixture)

            #expect(origins == [.carPlay], "\(testCase.name)")
        }
    }

    /// Promote, Retire and Restore each save the move inside the action, so
    /// the origin is whatever is current when that save lands.
    @Test func curationIsAttributedToCarPlay() async throws {
        final class Origins: @unchecked Sendable { var seen: [MusicKitActivityOrigin?] = [] }
        func originsOfSaves(role: PlaylistRole, arrange: Arrange, action: CarPlayAction) async throws -> [MusicKitActivityOrigin?] {
            let fixture = try PlaybackFixture(role: role); defer { fixture.cleanUp() }
            try await arrange(fixture)
            let origins = Origins()
            let observer = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave, object: fixture.context, queue: nil
            ) { _ in origins.seen.append(MusicKitActivityLog.currentOrigin) }
            defer { NotificationCenter.default.removeObserver(observer) }

            _ = await perform(action, on: fixture)

            return origins.seen
        }
        let retiredFirstSong: Arrange = { fixture in
            stubAppleMusic(fixture)
            try fixture.item(0).skipCount = 2
            try fixture.context.save()
            try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired",
                                               context: fixture.context)
            let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
            await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired,
                                                  settings: fixture.settings, context: fixture.context)
        }
        let retiring: Arrange = { fixture in
            stubAppleMusic(fixture)
            await playing(0, in: fixture)
        }

        let promote = try await originsOfSaves(role: .triageBucket, arrange: { try await playingInTriage($0) }, action: .promote)
        let retire = try await originsOfSaves(role: .oneTruePlaylist, arrange: retiring, action: .retire)
        let restore = try await originsOfSaves(role: .oneTruePlaylist, arrange: retiredFirstSong, action: .restore)

        for (name, origins) in [("promote", promote), ("retire", retire), ("restore", restore)] {
            #expect(!origins.isEmpty, "\(name) saved nothing")
            #expect(origins.allSatisfy { $0 == .carPlay }, "\(name): \(origins)")
        }
    }
}
