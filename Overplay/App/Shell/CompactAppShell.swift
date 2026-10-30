import SwiftUI

struct CompactAppShell: View {
    var settings: OverplaySettings

    @State private var path: [AppShellDestination]
    @Environment(\.compactHome) private var compactHome
    @Environment(\.shellNavigator) private var shellNavigator

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
        // Opened on another screen, the root page has not appeared to say so.
        .onAppear { compactHome?.isAway = !path.isEmpty }
        // The root page links by value, so emptying the path pops every
        // screen above it, with the stack's own animation.
        .onChange(of: compactHome?.returnRequests) { path = [] }
        // Opened from Now Playing: from the root page, as if chosen there.
        .onChange(of: shellNavigator?.request) { _, request in
            guard let request else { return }
            path = request.destination == .dashboard ? [] : [request.destination]
        }
    }
}
