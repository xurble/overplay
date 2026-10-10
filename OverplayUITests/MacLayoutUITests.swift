import XCTest

/// The Mac's column layout, run on the iPad simulator with
/// `-OverplayMacLayout`: Now Playing is a column that can be hidden, and the
/// toggle stays on every screen of the detail stack, not just its first.
final class MacLayoutUITests: XCTestCase {
    @MainActor private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private var playerTitle: XCUIElement { element("now-playing-title") }

    @MainActor private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor private func launch() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The column layout is for regular width.")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-OverplayUITesting", "-OverplayMacLayout"]
        app.launch()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 20), "The Now Playing column should appear")
    }

    @MainActor func testToggleStaysOnPushedScreens() throws {
        try launch()
        XCTAssertTrue(app.buttons["Hide Now Playing"].waitForExistence(timeout: 10), "The dashboard should have the toggle")

        let row = element("detail-dashboard").buttons.matching(NSPredicate(format: "label BEGINSWITH 'Overplay'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The dashboard should list Overplay")
        tap(row)
        XCTAssertTrue(app.buttons["Shuffle and Play"].waitForExistence(timeout: 10), "The Overplay playlist should open")
        XCTAssertTrue(app.buttons["Hide Now Playing"].waitForExistence(timeout: 5), "A pushed playlist should keep the toggle")

        tap(app.buttons["Hide Now Playing"])
        XCTAssertTrue(playerTitle.waitForNonExistence(timeout: 5), "The player should hide from a pushed screen")
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5), "The toggle should offer to show it again")
        tap(app.buttons["Show Now Playing"])
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 5), "The player should come back")
    }

    @MainActor func testToggleStaysTwoScreensDeep() throws {
        try launch()
        let settings = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "The dashboard should have Settings")
        tap(settings)
        let duplicates = app.buttons["Find Duplicates"]
        XCTAssertTrue(duplicates.waitForExistence(timeout: 10), "Settings should open")
        XCTAssertTrue(app.buttons["Hide Now Playing"].exists, "Settings should keep the toggle")
        tap(duplicates)
        XCTAssertTrue(duplicates.waitForNonExistence(timeout: 10), "Find Duplicates should open")
        XCTAssertTrue(app.buttons["Hide Now Playing"].waitForExistence(timeout: 5), "A second pushed screen should keep the toggle")
    }
}
