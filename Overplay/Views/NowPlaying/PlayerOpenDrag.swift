import Foundation
import Observation

/// A swipe up on the mini player, shared with the full-screen player it
/// opens so the player grows in step with the finger. The touch stays with
/// the mini player's gesture after the player appears over it.
@Observable
final class PlayerOpenDrag {
    enum Outcome { case open, cancel }

    /// The player's close progress while the finger is down: 1 is the mini
    /// player, 0 fully open. Nil when no swipe is in progress.
    var progress: CGFloat?
    /// Set on release; the player finishes opening or shrinks back.
    var outcome: Outcome?

    /// Progress for a finger moved up by `distance` from a mini player whose
    /// top is `miniPlayerTop` down the screen: fully open once the card's
    /// top, following the finger, reaches the top of the screen.
    static func progress(draggedUp distance: CGFloat, miniPlayerTop: CGFloat) -> CGFloat {
        1 - min(max(distance, 0) / max(miniPlayerTop, 1), 1)
    }
}
