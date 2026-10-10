import SwiftUI

/// Where the player lives, decided by the width class alone, never the
/// device type: a mini player that opens a full-screen player over the
/// compact layout (iPhone, a narrow window, a folded phone) and a column beside the regular one (iPad, a wide window,
/// an unfolded phone). Folding or resizing switches it while running;
/// playback state lives in the shared controller, so nothing restarts.
enum PlayerPlacement: Equatable {
    case sheet
    case column

    init(_ horizontalSizeClass: UserInterfaceSizeClass?) {
        self = horizontalSizeClass == .compact ? .sheet : .column
    }
}
