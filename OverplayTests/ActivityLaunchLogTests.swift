import AVFoundation
import Foundation
import Testing
@testable import Overplay

/// Every launch writes every event to its own file, so the session that
/// failed survives the force-quit that recovers it (#84).
@Suite("Activity launch logs", .serialized)
struct ActivityLaunchLogTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayLaunchLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func log(in folder: URL, maximumLaunchLogs: Int = 10, maximumBytes: Int = 5_000_000) -> MusicKitActivityLog {
        MusicKitActivityLog(fileURL: folder.appendingPathComponent("musickit-activity.json"), persistDelay: .seconds(3600),
                            maximumLaunchLogs: maximumLaunchLogs, maximumLaunchLogBytes: maximumBytes)
    }

    private func lines(_ url: URL) throws -> [MusicKitActivityEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(MusicKitActivityEvent.self, from: Data($0.utf8))
        }
    }

    @Test func eachLaunchWritesEveryEventToItsOwnFile() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = log(in: folder)
        first.record(.playerPrepare, detail: "first launch")
        // High-frequency events are only tallied in the summary, but every
        // one is in the launch's file.
        for _ in 0..<3 { first.record(.playbackQueueInvalidation) }
        first.flush()
        first.record(.playerPlay)
        first.flush()

        let second = log(in: folder)
        second.record(.playerPause, detail: "second launch")
        second.flush()

        let files = second.launchLogs()
        #expect(files.count == 2)
        let firstEvents = try lines(files[0])
        #expect(firstEvents.map(\.operation) == [.playerPrepare, .playbackQueueInvalidation, .playbackQueueInvalidation,
                                                 .playbackQueueInvalidation, .playerPlay])
        #expect(try lines(files[1]).map(\.detail) == ["second launch"])
        #expect(first.snapshot().events.map(\.operation) == [.playerPrepare, .playerPlay])
    }

    @Test func concurrentFlushesNeitherTearNorSplitTheFile() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let launch = log(in: folder)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for index in 0..<50 {
                        launch.record(.playerPlay, detail: "\(writer)-\(index)")
                        launch.flush()
                    }
                }
            }
        }
        launch.flush()
        let files = launch.launchLogs()
        #expect(files.count == 1)
        let events = try lines(try #require(files.first))
        #expect(events.count == 400)
        #expect(Set(events.compactMap(\.detail)).count == 400)
    }

    @Test func aRepeatedDiagnosticNoteIsPersistedOncePerMinute() {
        let message = "repeated note \(UUID().uuidString)"
        let now = Date()
        #expect(TrackMetadataDiagnostics.shouldPersist(message, now: now))
        #expect(!TrackMetadataDiagnostics.shouldPersist(message, now: now.addingTimeInterval(30)))
        #expect(TrackMetadataDiagnostics.shouldPersist(message, now: now.addingTimeInterval(61)))
    }

    @Test func aLaunchThatRecordsNothingLeavesNoFile() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let quiet = log(in: folder)
        quiet.flush()
        #expect(quiet.launchLogs().isEmpty)
    }

    @Test func onlyTheNewestLaunchesAreKept() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<5 {
            let launch = log(in: folder, maximumLaunchLogs: 3)
            launch.record(.playerPlay, detail: "launch \(index)")
            launch.flush()
            // Launch files are named by launch time to the millisecond.
            try await Task.sleep(for: .milliseconds(5))
        }
        let files = log(in: folder, maximumLaunchLogs: 3).launchLogs()
        #expect(try files.map { try lines($0).first?.detail } == ["launch 2", "launch 3", "launch 4"])
    }

    @Test func aLaunchPastTheSizeLimitKeepsItsNewestEvents() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = log(in: folder, maximumBytes: 4_000)
        for index in 0..<100 {
            big.record(.playerPlay, detail: "event \(index)")
            big.flush()
        }
        let file = try #require(big.launchLogs().first)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size <= 4_000)
        let kept = try lines(file)
        #expect(kept.last?.detail == "event 99")
        #expect(kept.count < 100)
    }

    @Test func clearingRecordedActivityDeletesTheLaunchLogs() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let launch = log(in: folder)
        launch.record(.playerPlay)
        launch.flush()
        #expect(launch.launchLogs().count == 1)
        launch.reset()
        #expect(launch.launchLogs().isEmpty)
    }

    @Test func sharingSendsTheSummaryAndEveryLaunchLog() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let launch = log(in: folder)
        launch.record(.playerPlay)
        let files = launch.shareableFiles()
        #expect(files.map(\.lastPathComponent).first == "musickit-activity.json")
        #expect(files.count == 2)
    }

    @Test func aFailureRecordsItsWholeErrorChain() throws {
        let log = MusicKitActivityLog(fileURL: nil)
        let underlying = NSError(domain: "MPErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "timed out"])
        let error = NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6, userInfo: [NSUnderlyingErrorKey: underlying])
        log.record(.playerPrepare, error: error)

        let detail = try #require(log.snapshot().events.first?.errorDetail)
        #expect(detail.contains("MPMusicPlayerControllerErrorDomain"))
        #expect(detail.contains("MPErrorDomain 7"))
        #expect(detail.contains("timed out"))
    }

    @Test func audioSessionInterruptionsAreDescribed() {
        let began = Notification(name: AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        let ended = Notification(name: AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ])
        #expect(AudioSessionEventRecorder.describeInterruption(began) == "interruption began")
        #expect(AudioSessionEventRecorder.describeInterruption(ended) == "interruption ended shouldResume=true")
    }
}
