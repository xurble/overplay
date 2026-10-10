import SwiftUI

struct CompactAppShell: View {
    var settings: OverplaySettings

    @State private var path: [AppShellDestination]

    /// Opened in place of the regular shell (folding an iPhone Duo, a
    /// narrower window), it starts on that shell's screen.
    init(settings: OverplaySettings, place: AppShellDestination?) {
        self.settings = settings
        _path = State(initialValue: place.flatMap { $0 == .dashboard ? nil : [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            DashboardView(settings: settings)
                .navigationDestination(for: AppShellDestination.self) { destination in
                    AppShellDestinationView(destination: destination, settings: settings)
                }
        }
    }
}
