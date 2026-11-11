import Foundation
import Testing
@testable import Overplay

/// The unit-test host keeps tests off the device's on-disk playback cache and
/// activity log.
@MainActor
struct TestHostIsolationTests {
    @Test func unitTestHostIsDetected() {
        #expect(TestHost.isHostingUnitTests)
    }

    @Test func fixtureTracksAreCachedInMemoryOnly() throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        let directory = URL.cachesDirectory.appendingPathComponent("Overplay/PlaybackTracks", isDirectory: true)
        for track in fixture.tracks {
            #expect(DevicePlaybackCache.shared.data(for: track.id) != nil)
            let file = directory.appendingPathComponent("\(track.id.uuidString).json")
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func activityLogsHaveNoBackingFiles() throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        for log in [fixture.controller.activityLog, MusicKitActivityLog.shared] {
            log.record(.diagnosticNote, detail: "test host isolation")
            #expect(log.shareableFiles().isEmpty)
        }
        #expect(fixture.controller.activityLog !== MusicKitActivityLog.shared)
    }
}
