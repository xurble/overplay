import SwiftUI

/// Where the player lives, decided by the width class alone, never the
/// device type: a mini player that opens a full-screen player over the
/// compact layout (iPhone, a narrow window, a folded phone) and a column beside the regular one (iPad, a wide window,
/// an unfolded phone). Folding or resizing switches it while running;
/// playback state lives in the shared controller, so nothing restarts.
enum PlayerPlacement: Equatable {
    case sheet
    case column

    /// Compact height (a phone in landscape, only while its full-screen
    /// player is open) keeps the compact layout, even where the landscape
    /// width is regular, so the open player stays open.
    init(_ horizontalSizeClass: UserInterfaceSizeClass?, _ verticalSizeClass: UserInterfaceSizeClass?) {
        self = horizontalSizeClass == .compact || verticalSizeClass == .compact ? .sheet : .column
    }
}
