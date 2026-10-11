import SwiftData
import SwiftUI

/// Settings in its own window, on a Mac, as a Mac app's: General and
/// Troubleshooting tabs, and only a close button. iPhone and iPad show
/// Settings in the app's navigation instead.
struct SettingsWindowView: View {
    static let windowID = "settings"

    let runtime: AppRuntime
    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    @State private var pane: SettingsView.Pane = .general
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var isPushed = false
    @State private var windowHandle = MacWindowHandle()

    private static let width: CGFloat = 800
    /// Room for a page pushed from the controls.
    private static let pushedHeight: CGFloat = 640
    private static let bottomPadding: CGFloat = 0

    /// Opens the Settings window, or brings the open one forward.
    static func open(with openWindow: OpenWindowAction) {
        openWindow(id: windowID, value: windowID)
    }

    var body: some View {
        Group {
            if let settings = settingsRecords.first {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SettingsWindowHeader(pane: $pane)
                        Divider()
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    NavigationStack {
                        SettingsView(settings: settings, pane: pane,
                                     onMacContentHeight: { contentHeight = $0 },
                                     onMacPushChange: { isPushed = $0 })
                    }
                    .id(pane)
                }
                // Into the hidden title bar, so the title sits beside the close button.
                .ignoresSafeArea(.container, edges: .top)
                // One light background, title bar and content alike.
                .background(Color(uiColor: .systemBackground))
            } else {
                ContentUnavailableView("Settings Unavailable", systemImage: "gearshape",
                                       description: Text("Open Overplay's main window first."))
            }
        }
        .environment(runtime)
        .environment(runtime.authorizationService)
        .environment(runtime.playbackController)
        .background(MacWindowConfigurator(title: "Overplay Settings", width: Self.width, handle: windowHandle))
        // Just tall enough for the controls; the top edge stays put.
        .onChange(of: windowHeight) { _, height in
            if let height { windowHandle.resize(height: height) }
        }
    }

    private var windowHeight: CGFloat? {
        guard headerHeight > 0, contentHeight > 0 else { return nil }
        return headerHeight + (isPushed ? Self.pushedHeight : contentHeight + Self.bottomPadding)
    }
}

/// A Mac settings window's header, drawn where the title bar was: the title
/// centred beside the close button, then the panes as icon-over-label tabs,
/// the selected one in the accent colour on a rounded highlight.
private struct SettingsWindowHeader: View {
    @Binding var pane: SettingsView.Pane

    private static let tabs: [(pane: SettingsView.Pane, systemImage: String)] = [
        (.general, "gearshape"),
        (.troubleshooting, "wrench.and.screwdriver")
    ]

    var body: some View {
        VStack(spacing: 8) {
            Text("Overplay Settings")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(height: 28)
            HStack(spacing: 6) {
                ForEach(Self.tabs, id: \.pane) { tab in
                    Button {
                        pane = tab.pane
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 24))
                                .frame(height: 28)
                            Text(tab.pane.title)
                                .font(.subheadline)
                        }
                        .frame(minWidth: 76)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(pane == tab.pane ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .modifier(SelectedTabGlass(isSelected: pane == tab.pane))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }
}

/// The selected tab is a glass button.
private struct SelectedTabGlass: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content.glassEffect(.regular, in: .rect(cornerRadius: 10))
        } else {
            content
        }
    }
}

/// Resizes a Mac window from SwiftUI, keeping its top edge: its frame
/// belongs to its UIKit scene. A height asked for before the scene is known
/// is applied once it is.
@MainActor
final class MacWindowHandle {
    var width: CGFloat = 0
    weak var window: UIWindow?
    weak var scene: UIWindowScene? {
        didSet { if let height { resize(height: height) } }
    }
    private var height: CGFloat?

    func resize(height: CGFloat) {
        // Never taller than the screen; the pane scrolls beyond that.
        let height = min(height, (window?.windowScene?.screen.bounds.height ?? .greatestFiniteMagnitude) - 120)
        self.height = height
#if targetEnvironment(macCatalyst)
        guard let scene else { return }
        // Mac scene frames are measured from the top, so keeping the origin
        // keeps the top edge. They are in Mac points, and the iPad-scaled
        // app draws smaller (77%): convert from the window's own points.
        // The live AppKit frame where there is one: the scene's lags behind an
        // animation.
        let frame = window.flatMap(MacAppKitWindow.frame(of:)) ?? scene.effectiveGeometry.systemFrame
        let scale = window.map { $0.bounds.height > 0 ? frame.height / $0.bounds.height : 1 } ?? 1
        let size = CGSize(width: ((width > 0 ? width : frame.width / scale) * scale).rounded(),
                          height: (height * scale).rounded())
        guard size != frame.size else { return }
        if let window, MacAppKitWindow.animateResize(of: window, to: size) { return }
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: size)))
#endif
    }
}

#if targetEnvironment(macCatalyst)
/// The AppKit window hosting a UIKit window, for what Mac Catalyst has no API
/// for. Reached at runtime; if AppKit changes, each call does nothing and
/// reports so.
@MainActor
enum MacAppKitWindow {
    static func nsWindow(for window: UIWindow) -> NSObject? {
        (NSClassFromString("NSApplication")?.value(forKeyPath: "sharedApplication.windows") as? [NSObject])?
            .first { ($0.value(forKey: "uiWindows") as? [UIWindow])?.contains(window) == true }
    }

    /// The AppKit frame, in Mac points.
    static func frame(of window: UIWindow) -> CGRect? {
        nsWindow(for: window).flatMap { ($0.value(forKey: "frame") as? NSValue)?.cgRectValue }
    }

    /// Resizes with AppKit's animation, keeping the top edge (AppKit frames
    /// are measured from the bottom). `size` is in Mac points.
    static func animateResize(of window: UIWindow, to size: CGSize) -> Bool {
        let selector = NSSelectorFromString("setFrame:display:animate:")
        guard let nsWindow = nsWindow(for: window), nsWindow.responds(to: selector),
              let frame = (nsWindow.value(forKey: "frame") as? NSValue)?.cgRectValue else { return false }
        let target = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        typealias SetFrame = @convention(c) (NSObject, Selector, CGRect, Bool, Bool) -> Void
        unsafeBitCast(nsWindow.method(for: selector), to: SetFrame.self)(nsWindow, selector, target, true, true)
        return true
    }
}
#endif

/// Names the window holding it and hands its scene to `handle`: a Mac
/// window's title and frame belong to its UIKit scene, which SwiftUI cannot
/// set.
private struct MacWindowConfigurator: UIViewRepresentable {
    var title: String
    var width: CGFloat
    var handle: MacWindowHandle

    func makeUIView(context: Context) -> ConfiguringView {
        ConfiguringView(title: title, width: width, handle: handle)
    }

    func updateUIView(_ uiView: ConfiguringView, context: Context) {}

    final class ConfiguringView: UIView {
        private let title: String
        private let width: CGFloat
        private let handle: MacWindowHandle
        private var configured = false

        init(title: String, width: CGFloat, handle: MacWindowHandle) {
            self.title = title
            self.width = width
            self.handle = handle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

#if targetEnvironment(macCatalyst)
        /// A Mac settings window can only be closed: minimize and zoom show
        /// disabled. Mac Catalyst has no API for the window's buttons, so this
        /// reaches the AppKit window hosting `window` at runtime; if AppKit
        /// changes, nothing happens.
        private static func disableMinimizeAndZoom(for window: UIWindow) {
            guard let nsWindow = MacAppKitWindow.nsWindow(for: window) else { return }
            let selector = NSSelectorFromString("standardWindowButton:")
            guard nsWindow.responds(to: selector) else { return }
            typealias ButtonGetter = @convention(c) (NSObject, Selector, Int) -> NSObject?
            let getButton = unsafeBitCast(nsWindow.method(for: selector), to: ButtonGetter.self)
            // NSWindow.ButtonType: 1 minimize, 2 zoom.
            for kind in [1, 2] {
                getButton(nsWindow, selector, kind)?.setValue(false, forKey: "enabled")
            }
        }
#endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !configured, let scene = window?.windowScene else { return }
            configured = true
            scene.title = title
#if targetEnvironment(macCatalyst)
            // The header draws the title, centred as a Mac settings window's.
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            // Sized to its controls (`MacWindowHandle`), never wide.
            scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 160)
            scene.sizeRestrictions?.maximumSize = CGSize(width: width + 240, height: .greatestFiniteMagnitude)
            handle.width = width
            let handle = handle
            let window = window
            Task { @MainActor in
                // The AppKit window, and a restored window's saved frame,
                // arrive just after the UIKit one.
                try? await Task.sleep(for: .milliseconds(150))
                handle.window = window
                handle.scene = scene
                if let window { Self.disableMinimizeAndZoom(for: window) }
            }
#endif
        }
    }
}

#Preview {
    SettingsWindowView(runtime: .shared)
        .modelContainer(PreviewContainer.make())
}
