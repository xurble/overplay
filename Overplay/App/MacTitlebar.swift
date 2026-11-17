import SwiftUI
import UIKit

extension View {
    /// On a Mac the window shows no title: in the Mac idiom each screen's bar
    /// sits in the window's toolbar, beside the window controls. Does nothing
    /// elsewhere.
    func hidesMacTitlebar() -> some View {
        onAppear {
#if targetEnvironment(macCatalyst)
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
            }
#endif
        }
    }
}

extension View {
    /// On a Mac the window can't be made smaller than `size`, in the app's
    /// own points. Set on this view's own window, so other windows keep
    /// their limits. Does nothing elsewhere.
    func macMinimumWindowSize(_ size: CGSize) -> some View {
        background { MacMinimumWindowSize(size: size).frame(width: 0, height: 0) }
    }
}

private struct MacMinimumWindowSize: UIViewRepresentable {
    var size: CGSize

    func makeUIView(context: Context) -> SizeView {
        let view = SizeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SizeView, context: Context) {
        uiView.size = size
    }

    final class SizeView: UIView {
        var size: CGSize = .zero {
            didSet { apply() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
#if targetEnvironment(macCatalyst)
            window?.windowScene?.sizeRestrictions?.minimumSize = size
#endif
        }
    }
}

extension View {
    /// On a Mac only one player window: another, restored or opened from the
    /// Dock, closes and the first comes forward (owner request, 2026-10-31).
    /// Does nothing elsewhere.
    func macSinglePlayerWindow() -> some View {
        background { MacSinglePlayerWindow().frame(width: 0, height: 0) }
    }
}

private struct MacSinglePlayerWindow: UIViewRepresentable {
    func makeUIView(context: Context) -> ClaimView {
        let view = ClaimView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ClaimView, context: Context) {}

    final class ClaimView: UIView {
        /// The player window's scene, the first to appear.
        private static weak var playerScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
#if targetEnvironment(macCatalyst)
            guard let scene = window?.windowScene else { return }
            if let existing = Self.playerScene, existing !== scene, existing.activationState != .unattached {
                UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
                UIApplication.shared.requestSceneSessionActivation(existing.session, userActivity: nil, options: nil)
            } else {
                Self.playerScene = scene
                MacFullScreen.shared.start(playerScene: scene)
                MacWindowFrameMemory.shared.start(playerScene: scene)
                MacAppKitWindow.disallowAutomaticTabbing()
                MacAppKitWindow.floatsNewWindowsOverFullScreen(besides: scene)
            }
#endif
        }
    }
}

/// Whether the player window is in macOS full screen, where it shows only the
/// full-screen player (`MacFullScreenPlayer`). There AppKit draws the window
/// toolbar as an opaque band, so in full screen the toolbar hides itself and
/// the window's is swapped for an empty one: only the traffic lights slide in
/// with the menu bar. Leaving full screen hands the toolbar
/// back to UIKit. Always false elsewhere.
@MainActor @Observable final class MacFullScreen {
    static let shared = MacFullScreen()
    private(set) var isFullScreen = false
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var started = false

    /// Follows the player window's scene in and out of full screen.
    func start(playerScene: UIWindowScene) {
#if targetEnvironment(macCatalyst)
        scene = playerScene
        // At rest the toolbar's band goes too, and the player reaches the
        // top; with the pointer at the top, the menu bar and the traffic
        // lights slide in, over an empty toolbar.
        playerScene.titlebar?.autoHidesToolbarInFullScreen = true
        apply(playerScene.isFullScreen)
        guard !started else { return }
        started = true
        // The scene reports full screen only once the move has finished, so
        // the "will" notifications switch early, before the animation, and
        // the "did" ones settle on what the scene reports (nil). Only the
        // player window can be made full screen.
        let changes: [(String, Bool?)] = [
            ("NSWindowWillEnterFullScreenNotification", true),
            ("NSWindowDidEnterFullScreenNotification", nil),
            ("NSWindowWillExitFullScreenNotification", false),
            ("NSWindowDidExitFullScreenNotification", nil),
        ]
        for (name, isFullScreen) in changes {
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let shared = MacFullScreen.shared
                    guard let scene = shared.scene else { return }
                    shared.apply(isFullScreen ?? scene.isFullScreen)
                }
            }
        }
#endif
    }

    private func apply(_ fullScreen: Bool) {
#if targetEnvironment(macCatalyst)
        guard fullScreen != isFullScreen, let titlebar = scene?.titlebar else { return }
        isFullScreen = fullScreen
        if fullScreen {
            let toolbar = NSToolbar(identifier: "FullScreen")
            toolbar.isVisible = false
            titlebar.toolbar = toolbar
        } else {
            titlebar.toolbar = nil
        }
#endif
    }
}

/// The player window's place and size on the Mac, kept across launches
/// (owner request, 2026-11-17). Catalyst brings a window back only through
/// macOS state restoration, which "Close windows when quitting an app", the
/// default, turns off. Full screen is not kept: a relaunch opens the last
/// windowed frame. Does nothing elsewhere.
@MainActor final class MacWindowFrameMemory {
    static let shared = MacWindowFrameMemory()
    static let defaultsKey = "overplay.macPlayerWindowFrame"
    private var observation: NSKeyValueObservation?

    func start(playerScene scene: UIWindowScene) {
#if targetEnvironment(macCatalyst)
        if !scene.isFullScreen, let saved = Self.savedFrame {
            scene.requestGeometryUpdate(.Mac(systemFrame: saved))
        }
        observation = scene.observe(\.effectiveGeometry, options: [.new]) { scene, _ in
            MainActor.assumeIsolated {
                // Full screen, and the move into it, which the scene reports
                // only once it has finished.
                guard !scene.isFullScreen, !MacFullScreen.shared.isFullScreen else { return }
                Self.save(scene.effectiveGeometry.systemFrame)
            }
        }
#endif
    }

    static var savedFrame: CGRect? {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let frame = NSCoder.cgRect(for: value)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    static func save(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        UserDefaults.standard.set(NSCoder.string(for: frame), forKey: defaultsKey)
    }
}
