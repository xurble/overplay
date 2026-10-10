import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("MusicKit diagnostics service")
struct MusicKitDiagnosticsServiceTests {
    @Test("player diagnostics only read and report a snapshot")
    func playerDiagnosticsOnlyReadAndReportSnapshot() {
        var readCount = 0
        let probe = MusicKitDiagnosticsPlayerProbe {
            readCount += 1
            return .init(playbackStatus: "playing", hasCurrentEntry: true)
        }
        var report = MusicKitDiagnosticsReport()

        probe.addDiagnostics(into: &report)

        #expect(readCount == 1)
        #expect(
            report.text == """
            ApplicationMusicPlayer status: playing
            ApplicationMusicPlayer current entry: present
            """
        )
    }

    @Test("edit probe reports an editable One True Playlist without attempting an edit")
    func editProbeReportsEditablePlaylist() async {
        var requestedIDs: [String] = []
        var probe = MusicKitDiagnosticsPlaylistEditProbe()
        probe.canEditOnThisDevice = { true }
        probe.fetchCanEdit = { requestedIDs.append($0); return true }
        var report = MusicKitDiagnosticsReport()

        await probe.addDiagnostics(for: Self.facts(), into: &report)

        #expect(requestedIDs == ["p.otp"])
        #expect(
            report.text == """
            One True Playlist: Overplay [p.otp]
            One True Playlist writes: managed
            One True Playlist edit refusal: none recorded
            Apple Music API canEdit: true
            This device can edit playlists: yes
            One True Playlist editable: yes as far as known: no refusal recorded; a lost ownership shows only when Overplay next removes a song
            """
        )
    }

    @Test("edit probe reports a recorded refusal as not editable")
    func editProbeReportsRecordedRefusal() async {
        var probe = MusicKitDiagnosticsPlaylistEditProbe()
        probe.canEditOnThisDevice = { true }
        probe.fetchCanEdit = { _ in true }
        var report = MusicKitDiagnosticsReport()

        await probe.addDiagnostics(for: Self.facts(editsRefusedAt: .now), into: &report)

        #expect(report.text.contains("One True Playlist edit refusal: refused "))
        #expect(report.text.hasSuffix("One True Playlist editable: no: Apple Music refused Overplay's edits; rebuild the playlist in Settings on iPhone or iPad"))
    }

    @Test("edit probe reports Apple Music's read-only answer and a Mac runtime")
    func editProbeReportsReadOnlyAndMac() async {
        var probe = MusicKitDiagnosticsPlaylistEditProbe()
        probe.canEditOnThisDevice = { false }
        probe.fetchCanEdit = { _ in false }
        var report = MusicKitDiagnosticsReport()

        await probe.addDiagnostics(for: Self.facts(), into: &report)

        #expect(report.text.contains("Apple Music API canEdit: false"))
        #expect(report.text.contains("This device can edit playlists: no (Mac; edits wait for iPhone or iPad)"))
        #expect(report.text.hasSuffix("One True Playlist editable: no: Apple Music reports the playlist as not editable"))
    }

    @Test("edit probe still gives a verdict when the canEdit request fails")
    func editProbeSurvivesFailedRequest() async {
        var probe = MusicKitDiagnosticsPlaylistEditProbe()
        probe.canEditOnThisDevice = { true }
        probe.fetchCanEdit = { _ in throw NSError(domain: "Test", code: 7) }
        var report = MusicKitDiagnosticsReport()

        await probe.addDiagnostics(for: Self.facts(allowsRemoteWrites: false), into: &report)

        #expect(report.text.contains("Apple Music API canEdit: failed: Test 7:"))
        #expect(report.text.contains("One True Playlist writes: incoming only"))
        #expect(report.text.hasSuffix("One True Playlist editable: no: the playlist is incoming only"))
    }

    @Test("edit probe reports a missing One True Playlist without any request")
    func editProbeReportsMissingPlaylist() async {
        var requested = false
        var probe = MusicKitDiagnosticsPlaylistEditProbe()
        probe.fetchCanEdit = { _ in requested = true; return true }
        var report = MusicKitDiagnosticsReport()

        await probe.addDiagnostics(for: nil, into: &report)

        #expect(!requested)
        #expect(report.text == "One True Playlist: none")
    }

    @Test("canEdit is read from the library playlist's attributes")
    func canEditIsReadFromAttributes() async throws {
        var requestedURL: URL?
        let canEdit = try await AppleMusicLibraryPlaylistResources.fetchCanEdit(playlistID: "p.otp") { url in
            requestedURL = url
            return Data(#"{"data":[{"id":"p.otp","type":"library-playlists","attributes":{"name":"Overplay","canEdit":false}}]}"#.utf8)
        }

        #expect(canEdit == false)
        #expect(requestedURL?.absoluteString == "https://api.music.apple.com/v1/me/library/playlists/p.otp")
    }

    @Test("a response without canEdit reports nothing")
    func missingCanEditReportsNil() async throws {
        let canEdit = try await AppleMusicLibraryPlaylistResources.fetchCanEdit(playlistID: "p.otp") { _ in
            Data(#"{"data":[{"id":"p.otp","type":"library-playlists","attributes":{"name":"Overplay"}}]}"#.utf8)
        }

        #expect(canEdit == nil)
    }

    private static func facts(allowsRemoteWrites: Bool = true, editsRefusedAt: Date? = nil) -> MusicKitDiagnosticsPlaylistEditProbe.Facts {
        .init(name: "Overplay", musicPlaylistID: "p.otp", allowsRemoteWrites: allowsRemoteWrites, editsRefusedAt: editsRefusedAt)
    }
}
