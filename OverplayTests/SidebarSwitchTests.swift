import SwiftUI
import Testing
@testable import Overplay

/// What a sidebar choice does to the regular-width list's path
/// (`SplitAppShell.sidebarSwitchPath`): every choice swaps the screen in
/// place behind a fade, so a choice that changes nothing must not fade.
@MainActor
@Suite("Sidebar switch")
struct SidebarSwitchTests {
    private func path(_ destinations: AppShellDestination...) -> NavigationPath { NavigationPath(destinations) }

    @Test func anotherScreenReplacesTheOneShown() {
        #expect(SplitAppShell.sidebarSwitchPath(to: .search, from: path(.retired), shown: .retired) == path(.search))
        #expect(SplitAppShell.sidebarSwitchPath(to: .retired, from: path(), shown: .dashboard) == path(.retired))
    }

    @Test func theDashboardEmptiesThePath() {
        #expect(SplitAppShell.sidebarSwitchPath(to: .dashboard, from: path(.retired), shown: .retired) == path())
    }

    /// No screen arrives to end a fade, so there is no switch: the screen
    /// shown, home, or one a dashboard link opened by value.
    @Test func theScreenAlreadyShownChangesNothing() {
        #expect(SplitAppShell.sidebarSwitchPath(to: .retired, from: path(.retired), shown: .retired) == nil)
        #expect(SplitAppShell.sidebarSwitchPath(to: .dashboard, from: path(), shown: .dashboard) == nil)
    }

    /// Inside a screen opened within it (pushed by view, so not in the
    /// path), the choice empties the path to leave it and is pushed again.
    @Test func choosingAScreenAgainFromInsideItReturnsToItsTop() {
        #expect(SplitAppShell.sidebarSwitchPath(to: .settings, from: path(.settings), shown: nil) == path())
    }

    /// The dashboard's path is already empty, so it cannot leave a screen
    /// opened inside it that way; it changes nothing rather than fading for
    /// a screen that never arrives.
    @Test func theDashboardCoveredByAScreenOpenedInsideItChangesNothing() {
        #expect(SplitAppShell.sidebarSwitchPath(to: .dashboard, from: path(), shown: nil) == nil)
    }
}
