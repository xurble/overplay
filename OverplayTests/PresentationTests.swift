import Foundation
import Testing
@testable import Overplay

@Suite("Playlist summary presentation")
struct PlaylistSummaryPresentationTests {
    @Test("role titles icons write labels and priorities match playlist roles")
    func roleTitlesIconsWriteLabelsAndPriorities() {
        let oneTrue = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Overplay",
            role: .oneTruePlaylist,
            writePolicy: .managed,
            activeTrackCount: 12,
            playableTrackCount: 11,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )
        let triage = PlaylistSummaryPresentation(
            id: UUID(),
            title: "Inbox",
            role: .triage,
            writePolicy: .incomingOnly,
            activeTrackCount: 1,
            playableTrackCount: 1,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: true
        )

        #expect(oneTrue.roleTitle == "One True Playlist")
        #expect(oneTrue.shortRoleTitle == "Main")
        #expect(oneTrue.iconIntent.systemImage == "star.fill")
        #expect(oneTrue.displayPriority == 0)
        #expect(oneTrue.writePolicyTitle == "Managed")

        #expect(triage.roleTitle == "Triage Playlist")
        #expect(triage.shortRoleTitle == "Triage")
        #expect(triage.iconIntent.systemImage == "play.fill")
        #expect(triage.displayPriority == 1)
        #expect(triage.writePolicyTitle == "Incoming only")
    }

    @Test("display ordering puts main playlists first then sorts names case-insensitively")
    func displayOrdering() {
        let summaries = [
            summary(title: "zeta", role: .triage),
            summary(title: "beta", role: .oneTruePlaylist),
            summary(title: "Alpha", role: .triage)
        ]

        let orderedTitles = summaries.sorted(by: PlaylistSummaryPresentation.areInDisplayOrder).map(\.title)

        #expect(orderedTitles == ["beta", "Alpha", "zeta"])
    }

    private func summary(title: String, role: PlaylistRole) -> PlaylistSummaryPresentation {
        PlaylistSummaryPresentation(
            id: UUID(),
            title: title,
            role: role,
            writePolicy: .managed,
            activeTrackCount: 0,
            playableTrackCount: 0,
            lastSyncedAt: nil,
            isCurrentPlaybackPlaylist: false
        )
    }
}

@Suite("Track summary presentation")
struct TrackSummaryPresentationTests {
    @Test("subtitle includes non-empty album title")
    func subtitleIncludesAlbumTitle() {
        let presentation = TrackSummaryPresentation(
            id: UUID(),
            title: "Go",
            artistName: "Artist",
            albumTitle: "Album",
            skipCount: 0
        )

        #expect(presentation.subtitle == "Artist - Album")
    }

    @Test("subtitle falls back to artist for missing or empty album")
    func subtitleFallsBackToArtist() {
        #expect(track(albumTitle: nil).subtitle == "Artist")
        #expect(track(albumTitle: "").subtitle == "Artist")
    }

    @Test("skip labels are singular plural and hidden at zero")
    func skipLabels() {
        #expect(track(skipCount: 0).skipCountLabel == nil)
        #expect(track(skipCount: 1).skipCountLabel == "1 skip")
        #expect(track(skipCount: 2).skipCountLabel == "2 skips")
        #expect(track(skipCount: 2).detailText == "Artist - 2 skips")
    }

    private func track(albumTitle: String? = nil, skipCount: Int = 0) -> TrackSummaryPresentation {
        TrackSummaryPresentation(
            id: UUID(),
            title: "Go",
            artistName: "Artist",
            albumTitle: albumTitle,
            skipCount: skipCount
        )
    }
}

@Suite("Track health presentation")
struct TrackHealthPresentationTests {
    @Test("health labels and icons prioritize protected and evicted state")
    func healthLabelsAndIcons() {
        let protected = TrackHealthPresentation(status: .critical, isEvicted: true, isProtected: true)
        let evicted = TrackHealthPresentation(status: .healthy, isEvicted: true, isProtected: false)
        let caution = TrackHealthPresentation(status: .caution, isEvicted: false, isProtected: false)

        #expect(protected.title == "Protected")
        #expect(protected.systemImage == "shield.fill")
        #expect(evicted.title == "Evicted")
        #expect(evicted.systemImage == "trash.fill")
        #expect(caution.title == "Caution")
        #expect(caution.systemImage == "exclamationmark.triangle.fill")
    }
}

@Suite("Now playing presentation")
struct NowPlayingPresentationTests {
    @Test("progress text formats finite invalid and nil durations")
    func progressTextFormatting() {
        #expect(NowPlayingPresentation.formatTime(0) == "0:00")
        #expect(NowPlayingPresentation.formatTime(65.9) == "1:05")
        #expect(NowPlayingPresentation.formatTime(.infinity) == "0:00")

        let presentation = NowPlayingPresentation(
            title: nil,
            artistName: nil,
            albumTitle: nil,
            progress: 0.5,
            elapsedSeconds: 125,
            durationSeconds: nil,
            skipCount: 2,
            evictAfterSkips: 3,
            isEvicted: false,
            isProtected: false
        )

        #expect(presentation.title == "Nothing playing")
        #expect(presentation.artistName == "Choose Play Overplay from the dashboard.")
        #expect(presentation.elapsedText == "2:05")
        #expect(presentation.durationText == "0:00")
        #expect(presentation.skipCountText == "Skips: 2 / 3")
    }
}
