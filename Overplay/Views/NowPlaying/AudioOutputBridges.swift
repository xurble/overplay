import AVKit
import MediaPlayer
import SwiftUI

/// Sets the system volume through a hidden `MPVolumeView`, the only way an
/// app can. The view is added straight to the app's window while the player
/// is open: hosted inside the glass pill, SwiftUI never kept it. While it is
/// attached the system volume overlay stays away, since the pill shows the
/// level itself. It relies on the view containing a `UISlider`; without one
/// (the simulator, or a later iOS) setting does nothing and reports false.
@MainActor
final class SystemVolumeControl {
    static let shared = SystemVolumeControl()

    private var volumeView: MPVolumeView?
    private var users = 0

    func attach() {
        users += 1
        attachIfNeeded()
    }

    func detach() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    @discardableResult
    func setVolume(_ volume: Float) -> Bool {
        attachIfNeeded()
        guard let slider = volumeView?.firstDescendant(of: UISlider.self) else { return false }
        slider.setValue(volume, animated: false)
        slider.sendActions(for: .valueChanged)
        return true
    }

    private func attachIfNeeded() {
        guard users > 0, volumeView?.window == nil, let window = Self.appWindow else { return }
        volumeView?.removeFromSuperview()
        // Off screen, and not hidden or fully transparent: either lets the
        // system overlay back.
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        volumeView = view
    }

    private static var appWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// Opens the system route picker, where AirPlay devices are chosen.
@MainActor
final class AudioRoutePickerControl {
    fileprivate weak var pickerView: AVRoutePickerView?

    /// `AVRoutePickerView` has no API to open its picker, so this presses
    /// the view's own button. False when there is none; the picker icon in
    /// the pill still opens it directly.
    @discardableResult
    func present() -> Bool {
        guard let button = pickerView?.firstDescendant(of: UIButton.self) else { return false }
        button.sendActions(for: .allEvents)
        return true
    }
}

/// The system route picker button, used as the pill's icon.
struct AudioRoutePickerView: UIViewRepresentable {
    var control: AudioRoutePickerControl
    var tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.accessibilityElementsHidden = true
        control.pickerView = view
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(tint)
        uiView.activeTintColor = UIColor(tint)
        control.pickerView = uiView
    }
}

private extension UIView {
    func firstDescendant<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
