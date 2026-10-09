import Foundation
import Testing
@testable import Overplay

/// A stuck player's advice reminds the user to take a sysdiagnose before
/// force-quitting, since the relaunch clears what it would capture (#90).
@Suite("Sysdiagnose reminder")
struct SysdiagnoseReminderTests {
    private func failure(_ kind: PlaybackFailure.Kind) -> PlaybackFailure {
        PlaybackFailure(kind: kind, message: "", since: .now)
    }

    @Test("only a stuck player is reminded")
    func shownOnlyWhenStuck() {
        #expect(SysdiagnoseReminder.isShown(for: failure(.stuck)))
        #expect(!SysdiagnoseReminder.isShown(for: failure(.command)))
        #expect(!SysdiagnoseReminder.isShown(for: failure(.stalled)))
        #expect(!SysdiagnoseReminder.isShown(for: nil))
    }

    @Test("each device is told its own way to start one")
    func startsPerDevice() {
        #expect(SysdiagnoseReminder.steps(for: .phone)[0].contains("both volume buttons and the side button"))
        #expect(SysdiagnoseReminder.steps(for: .pad)[0].contains("both volume buttons and the top button"))
        #expect(SysdiagnoseReminder.steps(for: .mac)[0].contains("Shift-Control-Option-Command-Period"))
    }

    @Test("the sysdiagnose is started before the force-quit", arguments: [
        SysdiagnoseReminder.Device.phone, .pad, .mac,
    ])
    func sysdiagnoseBeforeForceQuit(device: SysdiagnoseReminder.Device) throws {
        let steps = SysdiagnoseReminder.steps(for: device)
        let forceQuit = try #require(steps.firstIndex { $0.contains("force-quit") })
        #expect(forceQuit > 0)
        #expect(steps.last?.contains("Apple Music Call Activity") == true)
    }
}
