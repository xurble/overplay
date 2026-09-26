import SwiftUI

/// Routes artwork settings through the persistent player sheet's presenter.
@MainActor @Observable
final class PlaylistArtworkPresentation {
    struct Request: Identifiable {
        let id = UUID()
        let layout: PlaylistCollageLayout
        let stroke: PlaylistCollageStroke
        let save: (PlaylistCollageLayout, PlaylistCollageStroke) -> Void
    }

    var request: Request?

    func apply(layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke) {
        request?.save(layout, stroke)
        request = nil
    }
}
