import SwiftUI
import UIKit

extension View {
    /// On a Mac the window shows no title: in the Mac idiom each screen's bar
    /// sits in the window's toolbar, beside the window controls. Does nothing
    /// elsewhere.
    ///
    /// In full screen the toolbar hides with the menu bar and slides in over
    /// the window when the pointer reaches the top. Kept shown, it sat in a
    /// window of its own that the Mac fills with a solid band, and the
    /// sidebar's glass and the player's art stopped short below it.
    func hidesMacTitlebar() -> some View {
        onAppear {
#if targetEnvironment(macCatalyst)
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.autoHidesToolbarInFullScreen = true
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
            }
#endif
        }
    }
}
