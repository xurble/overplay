import SwiftUI
import UIKit

extension View {
    /// On a Mac the window has no separate title bar: the app's own bars
    /// reach the top beside the window controls, so the title-bar mini
    /// player can use that height. Does nothing elsewhere.
    func hidesMacTitlebar() -> some View {
        onAppear {
#if targetEnvironment(macCatalyst)
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
                MacWindowState.shared.watch(scene)
            }
#endif
        }
    }
}

/// Whether the Mac window is full screen, read when the scene's geometry
/// settles: window coordinates move as the hidden menu bar slides in, so
/// they cannot tell. Always false elsewhere.
@MainActor
@Observable
final class MacWindowState {
    static let shared = MacWindowState()

    private(set) var isFullScreen = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func watch(_ scene: UIWindowScene) {
        observation = scene.observe(\.effectiveGeometry, options: [.initial, .new]) { scene, _ in
            Task { @MainActor in MacWindowState.shared.isFullScreen = scene.isFullScreen }
        }
    }
}
