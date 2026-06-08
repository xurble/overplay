import SwiftUI

struct CompactAppShell: View {
    var settings: OverplaySettings

    var body: some View {
        NavigationStack {
            DashboardView(settings: settings)
        }
    }
}
