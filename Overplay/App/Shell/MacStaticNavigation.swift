import SwiftUI
import UIKit

extension View {
    /// On a Mac the list's screens change in place, as a sidebar choice does,
    /// rather than sliding (owner request, 2026-10-31). Set on a view inside
    /// the navigation stack. Does nothing elsewhere.
    func macStaticNavigation() -> some View {
        background { MacStaticNavigation().frame(width: 0, height: 0) }
    }
}

/// SwiftUI has no setting for a navigation stack's push and pop, so this
/// reaches the hosting navigation controller and stands in front of its
/// delegate, passing everything through but the transition, which it makes
/// instant. If UIKit changes, screens simply slide again.
private struct MacStaticNavigation: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HookView, context: Context) {}

    final class HookView: UIView {
        private let proxy = InstantTransitionDelegate()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        // The navigation controller joins the chain after the window, and
        // SwiftUI can set its delegate again.
        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        private func apply() {
#if targetEnvironment(macCatalyst)
            var responder: UIResponder? = next
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    guard navigation.delegate !== proxy else { return }
                    proxy.original = navigation.delegate
                    navigation.delegate = proxy
                    return
                }
                responder = current.next
            }
#endif
        }
    }
}

/// Forwards to the navigation controller's own delegate, with an instant
/// transition in place of its slide.
private final class InstantTransitionDelegate: NSObject, UINavigationControllerDelegate {
    // Read by the Objective-C runtime's forwarding, always on the main
    // thread for a navigation controller.
    nonisolated(unsafe) weak var original: UINavigationControllerDelegate?

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        InstantTransition()
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        nil
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

private final class InstantTransition: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0 }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if let view = transitionContext.view(forKey: .to) {
            if let destination = transitionContext.viewController(forKey: .to) {
                view.frame = transitionContext.finalFrame(for: destination)
            }
            transitionContext.containerView.addSubview(view)
        }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
