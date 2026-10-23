import SwiftUI
import UIKit

/// The full player's swipe down, as a UIKit pan: once it recognises, it
/// cancels the touch for everything under it, as a scroll view does, so a
/// swipe that started on a button never presses it. SwiftUI's own drag ran
/// alongside the button, and the card moving with the finger kept the finger
/// on the button until it lifted. It only begins for a drag more down than
/// across, so sideways drags (the volume pill) are left alone.
struct PlayerDismissPan: UIGestureRecognizerRepresentable {
    /// The finger's travel in the window.
    var onChanged: (CGSize) -> Void
    var onEnded: (_ translation: CGSize, _ predictedEnd: CGSize) -> Void
    /// The system took the touch (Control Center, a call).
    var onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The gestures tracking the same touch as this swipe, such as the
        /// press on the button it started on. UIKit asks about each of them.
        private let competing = NSHashTable<UIGestureRecognizer>.weakObjects()

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            competing.removeAllObjects()
            return true
        }

        /// Alongside the controls' own gestures: SwiftUI gives a child's
        /// (the button's) precedence, which kept this from ever beginning.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            competing.add(other)
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            let direction = velocity == .zero ? pan.translation(in: nil) : velocity
            return direction.y > abs(direction.x)
        }

        /// The press already under way on a button is cancelled the moment
        /// the swipe begins, so lifting the finger does not press it: turning
        /// a recogniser off and on cancels what it was tracking. Only the
        /// gestures sharing this touch are touched.
        func cancelCompetingGestures(than pan: UIGestureRecognizer) {
            for recognizer in competing.allObjects where recognizer !== pan && recognizer.isEnabled {
                switch recognizer.state {
                case .possible, .began, .changed:
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                default:
                    break
                }
            }
            competing.removeAllObjects()
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let translation = pan.translation(in: nil)
        let size = CGSize(width: translation.x, height: translation.y)
        switch pan.state {
        case .began:
            context.coordinator.cancelCompetingGestures(than: pan)
        case .changed:
            onChanged(size)
        case .ended:
            // About where a flick would carry on to, as SwiftUI predicts it.
            let velocity = pan.velocity(in: nil)
            onEnded(size, CGSize(width: translation.x + velocity.x * 0.25, height: translation.y + velocity.y * 0.25))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}
