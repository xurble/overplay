import OSLog
import SwiftData
import SwiftUI

/// Settings in its own window, on a Mac, as a Mac app's: General and
/// Troubleshooting tabs, and only a close button. iPhone and iPad show
/// Settings in the app's navigation instead.
struct SettingsWindowView: View {
    static let windowID = "settings"

    let runtime: AppRuntime
    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    /// Never inserted: a restored Mac with no row still reaches Nuke Database.
    @State private var unsavedDefaults = OverplaySettings()
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
            if let settings = AppRouter.shownSettings(settingsRecords, isLibraryReady: runtime.libraryRestoration.isReady,
                                                      unsavedDefaults: unsavedDefaults) {
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
    /// `value(forKey:)` on an object without the key raises an exception
    /// Swift cannot catch. `NSApp.windows` also holds windows that host no
    /// UIKit content, such as tooltips and popovers.
    private static func checkedValue(_ key: String, of object: NSObject) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    static func nsWindow(for window: UIWindow) -> NSObject? {
        (NSClassFromString("NSApplication")?.value(forKeyPath: "sharedApplication.windows") as? [NSObject])?
            .first { (checkedValue("uiWindows", of: $0) as? [UIWindow])?.contains(window) == true }
    }

    /// The AppKit frame, in Mac points.
    static func frame(of window: UIWindow) -> CGRect? {
        nsWindow(for: window).flatMap { (checkedValue("frame", of: $0) as? NSValue)?.cgRectValue }
    }

    /// macOS makes a new window a tab of a full-screen one when "Prefer tabs
    /// when opening documents" says so, the default being in full screen:
    /// Settings opened over the full-screen player became its tab. Overplay
    /// has one player window and Settings, never tabs.
    static func disallowAutomaticTabbing() {
        let selector = NSSelectorFromString("setAllowsAutomaticWindowTabbing:")
        guard let windowClass = NSClassFromString("NSWindow"),
              let method = class_getClassMethod(windowClass, selector) else {
            logger.error("Window tabbing: NSWindow has no setAllowsAutomaticWindowTabbing:")
            return
        }
        typealias Setter = @convention(c) (AnyClass, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(windowClass, selector, false)
    }

    /// Shown above a full-screen window, in its space, rather than taking a
    /// full-screen space or tab of its own: an auxiliary full-screen window,
    /// as the Music app's settings are, and never tabbed.
    static func floatsOverFullScreen(_ window: UIWindow) {
        guard let nsWindow = nsWindow(for: window) else {
            logger.error("Settings window: no AppKit window")
            return
        }
        floatsOverFullScreen(nsWindow)
    }

    private static func floatsOverFullScreen(_ nsWindow: NSObject) {
        guard let behavior = (checkedValue("collectionBehavior", of: nsWindow) as? NSNumber)?.uintValue else {
            logger.error("Window: no collection behaviour")
            return
        }
        // NSWindow.CollectionBehavior: fullScreenPrimary 1 << 7, auxiliary
        // 1 << 8, none 1 << 9. They exclude each other; a mix raises.
        let floating = (behavior & ~UInt(1 << 7 | 1 << 9)) | UInt(1 << 8)
        if floating != behavior {
            nsWindow.setValue(NSNumber(value: floating), forKey: "collectionBehavior")
        }
        // NSWindow.TabbingMode.disallowed.
        if nsWindow.responds(to: NSSelectorFromString("setTabbingMode:")) {
            nsWindow.setValue(NSNumber(value: 2), forKey: "tabbingMode")
        }
        let tabs = (checkedValue("tabbedWindows", of: nsWindow) as? [NSObject])?.count ?? 0
        logger.notice("Window: collection behaviour \(behavior, privacy: .public) -> \(floating, privacy: .public), tabs \(tabs, privacy: .public)")
    }

    /// Every other window (Settings) floats over a full-screen player from
    /// the start. Set once the window is on screen, it was too late: macOS
    /// had shown it as an ordinary window, which a full-screen space cannot
    /// hold, and left full screen to show it. A scene's AppKit window exists,
    /// still hidden, as the scene connects.
    static func floatsNewWindowsOverFullScreen(besides playerScene: UIWindowScene) {
        guard !observesNewScenes else { return }
        observesNewScenes = true
        self.playerScene = playerScene
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            // Posted on the main queue, which the observer asks for.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let scene = object as? UIWindowScene, scene !== Self.playerScene else { return }
                floatsHiddenWindowsOverFullScreen()
            }
        }
    }

    private static weak var playerScene: UIWindowScene?
    private static var observesNewScenes = false

    /// Hidden UIKit-hosting windows other than the player's: the one about
    /// to be shown.
    private static func floatsHiddenWindowsOverFullScreen() {
        let playerWindows = playerScene?.windows ?? []
        let windows = (NSClassFromString("NSApplication")?.value(forKeyPath: "sharedApplication.windows") as? [NSObject]) ?? []
        var floated = 0
        for nsWindow in windows {
            guard let uiWindows = checkedValue("uiWindows", of: nsWindow) as? [UIWindow],
                  !uiWindows.contains(where: { playerWindows.contains($0) }),
                  (checkedValue("isVisible", of: nsWindow) as? Bool) == false else { continue }
            floatsOverFullScreen(nsWindow)
            floated += 1
        }
        logger.notice("New window scene: \(floated, privacy: .public) hidden window(s) set to float over full screen")
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "Window")

    /// Resizes with AppKit's animation, keeping the top edge (AppKit frames
    /// are measured from the bottom). `size` is in Mac points.
    static func animateResize(of window: UIWindow, to size: CGSize) -> Bool {
        let selector = NSSelectorFromString("setFrame:display:animate:")
        guard let nsWindow = nsWindow(for: window), nsWindow.responds(to: selector),
              let frame = (checkedValue("frame", of: nsWindow) as? NSValue)?.cgRectValue else { return false }
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
            let setEnabled = NSSelectorFromString("setEnabled:")
            for kind in [1, 2] {
                guard let button = getButton(nsWindow, selector, kind), button.responds(to: setEnabled) else { continue }
                button.setValue(false, forKey: "enabled")
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
            // Never full screen itself: over a full-screen player it floats
            // above it, as the Music app's settings do, rather than taking a
            // full-screen space or tab of its own (owner request, 2026-11-17).
            scene.sizeRestrictions?.allowsFullScreen = false
            handle.width = width
            let handle = handle
            let window = window
            Task { @MainActor in
                // The AppKit window, and a restored window's saved frame,
                // arrive just after the UIKit one.
                try? await Task.sleep(for: .milliseconds(150))
                handle.window = window
                handle.scene = scene
                if let window {
                    Self.disableMinimizeAndZoom(for: window)
                    MacAppKitWindow.floatsOverFullScreen(window)
                }
            }
#endif
        }
    }
}

#Preview {
    SettingsWindowView(runtime: .shared)
        .modelContainer(PreviewContainer.make())
}
