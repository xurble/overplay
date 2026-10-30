import XCTest

/// Sidebar choices in the regular-width shell, through the sidebar panel, on
/// the iPad simulator's sample library (`-OverplayUITesting`). Each choice
/// swaps the list's screen in place behind a fade; these check where it
/// lands, which a stack that pops, pushes or drops a path gets wrong.
final class SidebarNavigationUITests: XCTestCase {
    @MainActor private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The sidebar panel is for regular width.")
        app.launchArguments = ["-OverplayUITesting"]
        app.launch()
        XCTAssertTrue(element("now-playing-title").waitForExistence(timeout: 20), "The Now Playing column should appear")
        if !isOnScreen(sidebar("dashboard")) {
            app.buttons["Show Sidebar"].firstMatch.tap()
        }
        XCTAssertTrue(waitUntil { self.isOnScreen(self.sidebar("dashboard")) }, "The sidebar panel should be open")
    }

    @MainActor private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @MainActor private func sidebar(_ item: String) -> XCUIElement { element("sidebar-\(item)") }
    @MainActor private func detail(_ destination: String) -> XCUIElement { element("detail-\(destination)") }

    /// Taps the element's centre through the app's own hit testing.
    @MainActor private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor private func isOnScreen(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        return element.exists && !element.frame.isEmpty && element.frame.maxX > 1 && element.frame.minX < window.maxX
    }

    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
        return condition()
    }

    @MainActor func testSidebarChoicesReplaceTheScreenAndBackLeadsHome() throws {
        try launch()
        tap(sidebar("retired"))
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("retired")) }, "Retired should be shown")

        tap(sidebar("settings"))
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("settings")) }, "Settings should replace Retired")
        XCTAssertFalse(detail("retired").exists, "Retired should be gone, not left beneath")

        // Choosing the screen shown changes nothing.
        tap(sidebar("settings"))
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("settings")) })

        // A sidebar screen sits on the dashboard: Back leads home.
        tap(app.buttons.matching(NSPredicate(format: "label IN %@", ["Overplay", "Back"])).firstMatch)
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("dashboard")) }, "Back should lead to the dashboard")
    }

    @MainActor func testChoosingAScreenAgainFromInsideItReturnsToItsTop() throws {
        try launch()
        tap(sidebar("settings"))
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("settings")) })
        // Find Duplicates is opened by view, so the list's path doesn't hold it.
        tap(element("settings-find-duplicates"))
        XCTAssertTrue(waitUntil { !self.isOnScreen(self.detail("settings")) }, "Find Duplicates should cover Settings")

        tap(sidebar("settings"))
        XCTAssertTrue(waitUntil { self.isOnScreen(self.detail("settings")) }, "Settings should come back to its top")
    }
}
