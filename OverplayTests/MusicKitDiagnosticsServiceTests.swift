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
}
