import Foundation
import UIKit

/// How to take a sysdiagnose while the player is stuck (#90). Its snapshot of
/// every process shows what Overplay's hung player call is waiting on, which
/// the activity log cannot, but only while Overplay is still stuck: before it
/// is force-quit.
enum SysdiagnoseReminder {
    enum Device: Equatable {
        case phone
        case pad
        case mac
    }

    static let buttonTitle = "Take a Sysdiagnose First"
    static let title = "Take a Sysdiagnose"
    static let explanation =
        "A sysdiagnose shows what Overplay is stuck waiting on. Take it before you force-quit: relaunching clears what it would show."

    /// Only a stuck player is shown the reminder: a relaunch clears the state
    /// the sysdiagnose would capture.
    static func isShown(for failure: PlaybackFailure?) -> Bool {
        failure?.kind == .stuck
    }

    @MainActor static var currentDevice: Device {
        if ProcessInfo.processInfo.isMacCatalystApp { return .mac }
        return UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }

    static func steps(for device: Device) -> [String] {
        switch device {
        case .phone, .pad:
            let button = device == .pad ? "top" : "side"
            return [
                "Press both volume buttons and the \(button) button together for about a second. Holding longer opens the power-off screen.",
                "Wait a minute, then force-quit Overplay and open it again.",
                "About 10 minutes later the sysdiagnose is in Settings → Privacy & Security → Analytics & Improvements → Analytics Data.",
                "Share it with Overplay's activity log from Settings → Apple Music Call Activity.",
            ]
        case .mac:
            return [
                "Press Shift-Control-Option-Command-Period. The screen flashes.",
                "Wait a minute, then force-quit Overplay with Option-Command-Escape and open it again.",
                "A few minutes later Finder opens the sysdiagnose in /private/var/tmp.",
                "Share it with Overplay's activity log from Settings → Apple Music Call Activity.",
            ]
        }
    }
}
