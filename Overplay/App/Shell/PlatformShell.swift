import SwiftUI

struct PlatformShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var place = ShellPlace()

    var settings: OverplaySettings

    var body: some View {
        let isMacFullScreen = MacFullScreen.shared.isFullScreen
        Group {
            // Switching shells rebuilds navigation; the new shell opens the
            // screen the old one last reported.
            if PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet {
                CompactAppShell(settings: settings, place: place.destination)
            } else {
                SplitAppShell(settings: settings, place: place.destination)
            }
        }
        .environment(\.shellPlace, place)
        // A Mac in full screen shows only the player. The shell stays,
        // hidden, so leaving full screen finds every screen as it was.
        .opacity(isMacFullScreen ? 0 : 1)
        .allowsHitTesting(!isMacFullScreen)
        .accessibilityHidden(isMacFullScreen)
        .overlay {
            if isMacFullScreen {
                NowPlayingColumnView(settings: settings, isMacFullScreen: true)
            }
        }
    }
}
