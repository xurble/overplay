import SwiftUI

struct PlatformShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var place = ShellPlace()

    var settings: OverplaySettings

    var body: some View {
        Group {
            // Switching shells rebuilds navigation; the new shell opens the
            // screen the old one last reported.
            if PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet {
                CompactAppShell(settings: settings, place: place.destination)
            } else {
                SplitAppShell(settings: settings, place: place.destination)
                    // The keyboard covers the shell rather than shortening
                    // it: shortened, open in portrait measured too little
                    // below the fold to stack and turned side by side (owner
                    // request, 2026-10-30).
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .environment(\.shellPlace, place)
    }
}
