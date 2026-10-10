import SwiftUI

/// Shows and hides the Now Playing column where it can be hidden (a Mac).
/// A toolbar item belongs to the screen on top of the stack, so every screen
/// the detail column can show or push carries `.nowPlayingColumnToggle()`;
/// without the environment value (iPhone, iPad) it adds nothing.
struct NowPlayingColumnToggle {
    var isShown: Bool
    var toggle: () -> Void
}

extension EnvironmentValues {
    @Entry var nowPlayingColumnToggle: NowPlayingColumnToggle?
}

extension View {
    func nowPlayingColumnToggle() -> some View {
        modifier(NowPlayingColumnToggleToolbar())
    }
}

private struct NowPlayingColumnToggleToolbar: ViewModifier {
    @Environment(\.nowPlayingColumnToggle) private var columnToggle

    func body(content: Content) -> some View {
        content.toolbar {
            if let columnToggle {
                ToolbarItem(placement: .primaryAction) {
                    let title = columnToggle.isShown ? "Hide Now Playing" : "Show Now Playing"
                    Button(action: columnToggle.toggle) {
                        Label(title, systemImage: "sidebar.trailing")
                    }
                    .help(title)
                }
            }
        }
    }
}
