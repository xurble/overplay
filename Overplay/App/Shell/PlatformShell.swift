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
            }
        }
        .environment(\.shellPlace, place)
    }
}
