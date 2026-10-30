import SwiftUI

/// Whether compact navigation has left the root page, and the way back: the
/// home button beside the mini player shows while away and returns there.
@MainActor
@Observable
final class CompactHome {
    /// The root page is not showing.
    var isAway = false
    /// Each request pops the compact stack to the root page.
    private(set) var returnRequests = 0

    func goHome() { returnRequests += 1 }
}

extension EnvironmentValues {
    @Entry var compactHome: CompactHome?
}

/// Asks whichever shell is showing to open a screen, from anywhere: Now
/// Playing's "playing from" line. The compact shell opens it from the root
/// page; the regular shell selects it in the sidebar or pushes it on the
/// dashboard. An open full-screen player closes first.
@MainActor
@Observable
final class ShellNavigator {
    struct Request: Equatable {
        var destination: AppShellDestination
        var id: Int
    }

    private(set) var request: Request?

    func show(_ destination: AppShellDestination) {
        request = Request(destination: destination, id: (request?.id ?? 0) + 1)
    }
}

extension EnvironmentValues {
    @Entry var shellNavigator: ShellNavigator?
}
