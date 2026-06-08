import SwiftUI

struct PlatformShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var settings: OverplaySettings

    var body: some View {
        if horizontalSizeClass == .compact {
            CompactAppShell(settings: settings)
        } else {
            SplitAppShell(settings: settings)
        }
    }
}
