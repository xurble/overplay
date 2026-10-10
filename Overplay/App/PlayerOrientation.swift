import SwiftUI
import UIKit

/// A phone stays in portrait except for its full-screen player, which follows
/// the phone into landscape. iPad and Mac follow the device as before.
@MainActor
enum PlayerOrientation {
    private static var allowsLandscape = false

    static var supportedOrientations: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return allowsLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    /// Asks the system again, so closing the player in landscape turns the
    /// app back to portrait.
    static func setFullScreenPlayerOpen(_ isOpen: Bool) {
        guard allowsLandscape != isOpen else { return }
        allowsLandscape = isOpen
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// Which way the phone was last turned into landscape, kept while it is
/// upright or flat, so the player's art stays on the edge that was the
/// phone's top: in a closed folding phone's landscape player and, once it
/// is opened from there, in the player above the fold.
@MainActor
@Observable
final class PhoneTurn {
    static let shared = PhoneTurn()

    /// Turned clockwise from portrait, the phone's top edge is on the right.
    private(set) var isClockwise = UIDevice.current.orientation == .landscapeRight

    private init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                switch UIDevice.current.orientation {
                case .landscapeRight: self?.isClockwise = true
                case .landscapeLeft: self?.isClockwise = false
                default: break
                }
            }
        }
    }
}

final class OverplayAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientation.supportedOrientations
    }
}
