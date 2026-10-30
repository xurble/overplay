import SwiftUI
import UIKit

/// The corner radii of a window that does not fill its screen, such as a
/// split window on an open Duo, where the corners at the hinge are tighter
/// than those at the screen's edge.
struct WindowCorners: Equatable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    /// Measured from UIKit: a view filling the window, its corners concentric
    /// with the window's, resolves each corner on its own.
    @MainActor
    static func measure() -> WindowCorners? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let probe = UIView(frame: window.bounds)
        probe.isUserInteractionEnabled = false
        probe.cornerConfiguration = .corners(radius: .containerConcentric())
        window.addSubview(probe)
        defer { probe.removeFromSuperview() }
        probe.layoutIfNeeded()
        return WindowCorners(
            topLeft: probe.effectiveRadius(corner: .topLeft),
            topRight: probe.effectiveRadius(corner: .topRight),
            bottomLeft: probe.effectiveRadius(corner: .bottomLeft),
            bottomRight: probe.effectiveRadius(corner: .bottomRight)
        )
    }
}
