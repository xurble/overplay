import SwiftUI

/// Shows and hides the Now Playing column where it can be hidden (a Mac),
/// with a mini player in the title bar while it is hidden. A toolbar item
/// belongs to the screen on top of the stack, so every screen the detail
/// column can show or push carries `.nowPlayingColumnToggle()`; without the
/// environment value (iPhone, iPad) it adds nothing.
struct NowPlayingColumnToggle {
    var isShown: Bool
    var settings: OverplaySettings
    var toggle: () -> Void
}

/// Slides the sidebar panel in and out where the list and player sit in
/// halves (an open iPhone Duo, an iPad wider than tall). It replaces the split
/// view's own sidebar button, which opened its sidebar over the list as well.
struct SidebarPanelToggle {
    var isShown: Bool
    /// Whether the toolbar shows the button.
    var showsButton = true
    var toggle: () -> Void
}

extension EnvironmentValues {
    @Entry var nowPlayingColumnToggle: NowPlayingColumnToggle?
    @Entry var sidebarPanelToggle: SidebarPanelToggle?
}

extension View {
    func nowPlayingColumnToggle() -> some View {
        modifier(NowPlayingColumnToggleToolbar())
    }
}

private struct NowPlayingColumnToggleToolbar: ViewModifier {
    @Environment(\.nowPlayingColumnToggle) private var columnToggle
    @Environment(\.sidebarPanelToggle) private var sidebarPanelToggle

    func body(content: Content) -> some View {
        content.toolbar {
            if let sidebarPanelToggle, sidebarPanelToggle.showsButton {
                ToolbarItem(placement: .topBarLeading) {
                    let title = sidebarPanelToggle.isShown ? "Hide Sidebar" : "Show Sidebar"
                    Button(action: sidebarPanelToggle.toggle) {
                        Label(title, systemImage: "sidebar.leading")
                    }
                    .help(title)
                    .untinted()
                }
            }
            if let columnToggle, !columnToggle.isShown {
                ToolbarItem(placement: .primaryAction) {
                    MiniPlayerToolbarView(settings: columnToggle.settings, onOpen: columnToggle.toggle)
                }
                // Its own glass, taller than the bar's.
                .sharedBackgroundVisibility(.hidden)
            }
            // While hidden, the toggle sits inside the mini player.
            if let columnToggle, columnToggle.isShown {
                ToolbarItem(placement: .primaryAction) {
                    let title = columnToggle.isShown ? "Hide Now Playing" : "Show Now Playing"
                    Button(action: columnToggle.toggle) {
                        Label(title, systemImage: "sidebar.trailing")
                    }
                    .help(title)
                    .untinted()
                }
            }
        }
    }
}
