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
            }
#endif
        }
    }
}
