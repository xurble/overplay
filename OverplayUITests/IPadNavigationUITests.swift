import XCTest

/// Navigation in the regular-width (iPad) layout: sidebar, list and the Now
/// Playing column, in both orientations. Runs the simulator build with a
/// fresh in-memory sample library and the simulated player
/// (`-OverplayUITesting`). The sample library's One True Playlist is
/// "Overplay" with 12 songs, including "Teardrop".
///
/// Taps go to the element's centre on screen, through the app's own hit
/// testing as a finger would. XCTest's own hittability check is not used:
/// it treats the column's oversized, non-interactive background art as
/// covering the list.
final class IPadNavigationUITests: XCTestCase {
    @MainActor private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    @MainActor
    private func launch(_ orientation: UIDeviceOrientation) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The column layout is for regular width.")
        addTeardownBlock { await MainActor.run { XCUIDevice.shared.orientation = .portrait } }
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = ["-OverplayUITesting"]
        app.launch()
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 20), "The Now Playing column should appear")
        try rotate(to: orientation)
    }

    /// Rotates and waits until the window really has that shape. Some
    /// simulators update the device orientation without rotating the app;
    /// there the test is skipped rather than run in the wrong orientation.
    /// Rotating the simulator by hand first lets the landscape tests run.
    @MainActor private func rotate(to orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation.isLandscape
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            let frame = window.frame
            if landscape ? frame.width > frame.height : frame.height > frame.width { return }
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
        }
        throw XCTSkip("This simulator does not rotate the app to \(landscape ? "landscape" : "portrait"); rotate it by hand and rerun.")
    }

    @MainActor private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @MainActor private func detail(_ destination: String) -> XCUIElement { element("detail-\(destination)") }
    @MainActor private func sidebar(_ item: String) -> XCUIElement { element("sidebar-\(item)") }
    @MainActor private var playerTitle: XCUIElement { element("now-playing-title") }
    @MainActor private var window: XCUIElement { app.windows.firstMatch }

    @MainActor private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// On screen: inside the window, not slid off its leading edge.
    @MainActor private func isOnScreen(_ element: XCUIElement) -> Bool {
        element.exists && element.frame.maxX > 1 && element.frame.minX < window.frame.maxX
    }

    @MainActor
    private func assertListBesidePlayer(_ list: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The list should exist", file: file, line: line)
        XCTAssertTrue(isOnScreen(playerTitle), "The player should be on screen", file: file, line: line)
        XCTAssertLessThanOrEqual(list.frame.maxX, playerTitle.frame.minX, "The player should be beside the list, not over it", file: file, line: line)
        XCTAssertLessThanOrEqual(playerTitle.frame.maxX, window.frame.maxX, "The player should be inside the window", file: file, line: line)
    }

    @MainActor private func openOverplayFromDashboard() {
        let row = detail("dashboard").buttons.matching(NSPredicate(format: "label BEGINSWITH 'Overplay'")).firstMatch
        // The first launch after an install can take a while to fill the list.
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The dashboard should list Overplay")
        tap(row)
        XCTAssertTrue(app.buttons["Shuffle and Play"].waitForExistence(timeout: 10), "The Overplay playlist should open")
    }

    // MARK: - Landscape: sidebar, list and player side by side

    @MainActor func testLandscapeShowsSidebarListAndPlayerSideBySide() throws {
        try launch(.landscapeLeft)
        XCTAssertTrue(isOnScreen(sidebar("dashboard")), "The sidebar should be visible in landscape")
        // The iOS 26 sidebar floats over the list's area; its rows start beside it.
        let row = detail("dashboard").buttons.matching(NSPredicate(format: "label BEGINSWITH 'Overplay'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let sidebarRow = app.cells.containing(.any, identifier: "sidebar-dashboard").firstMatch
        let rowTitle = row.staticTexts["Overplay"]
        XCTAssertGreaterThanOrEqual(rowTitle.frame.minX, sidebarRow.frame.maxX, "The list's content should be beside the sidebar")
        assertListBesidePlayer(detail("dashboard"))
    }

    @MainActor func testLandscapeSidebarChoiceChangesTheListAndKeepsThePlayer() throws {
        try launch(.landscapeLeft)
        tap(sidebar("retired"))
        assertListBesidePlayer(detail("retired"))
        tap(sidebar("dashboard"))
        assertListBesidePlayer(detail("dashboard"))
    }

    @MainActor func testLandscapeDashboardOpensAPlaylistBesideThePlayer() throws {
        try launch(.landscapeLeft)
        openOverplayFromDashboard()
        XCTAssertTrue(isOnScreen(playerTitle), "The player should stay beside the opened playlist")
        XCTAssertLessThanOrEqual(app.buttons["Shuffle and Play"].frame.maxX, playerTitle.frame.minX)
    }

    // MARK: - Portrait: list and player 60/40, sidebar over the list

    @MainActor func testPortraitSplitsListAndPlayerSixtyForty() throws {
        try launch(.portrait)
        XCTAssertFalse(isOnScreen(sidebar("dashboard")), "The sidebar should start hidden in portrait")
        assertListBesidePlayer(detail("dashboard"))
        XCTAssertEqual(detail("dashboard").frame.width / window.frame.width, 0.6, accuracy: 0.02, "The list should take 60%")
    }

    @MainActor func testPortraitSidebarOpensOverTheListAndClosesAfterAChoice() throws {
        try launch(.portrait)
        let showSidebar = app.buttons["Show Sidebar"]
        XCTAssertTrue(showSidebar.waitForExistence(timeout: 10), "There should be a Show Sidebar button")
        tap(showSidebar)
        let listWidth = detail("dashboard").frame.width
        let opened = expectation(for: NSPredicate { _, _ in self.isOnScreen(self.sidebar("retired")) }, evaluatedWith: nil)
        wait(for: [opened], timeout: 5)
        XCTAssertEqual(detail("dashboard").frame.width, listWidth, accuracy: 1, "The sidebar should slide over the list, not shrink it")
        tap(sidebar("retired"))
        let closed = expectation(for: NSPredicate { _, _ in !self.isOnScreen(self.sidebar("retired")) }, evaluatedWith: nil)
        wait(for: [closed], timeout: 5)
        assertListBesidePlayer(detail("retired"))
    }

    @MainActor func testPortraitDashboardOpensAPlaylistBesideThePlayer() throws {
        try launch(.portrait)
        openOverplayFromDashboard()
        XCTAssertTrue(isOnScreen(playerTitle), "The player should stay beside the opened playlist")
        XCTAssertLessThanOrEqual(app.buttons["Shuffle and Play"].frame.maxX, playerTitle.frame.minX)
    }

    @MainActor func testRotatingBetweenPortraitAndLandscapeKeepsTheLayoutRight() throws {
        try launch(.portrait)
        XCTAssertFalse(isOnScreen(sidebar("dashboard")), "Portrait starts without the sidebar")
        try rotate(to: .landscapeLeft)
        let sidebarBack = expectation(for: NSPredicate { _, _ in self.isOnScreen(self.sidebar("dashboard")) }, evaluatedWith: nil)
        wait(for: [sidebarBack], timeout: 10)
        assertListBesidePlayer(detail("dashboard"))
        try rotate(to: .portrait)
        let sidebarGone = expectation(for: NSPredicate { _, _ in !self.isOnScreen(self.sidebar("dashboard")) }, evaluatedWith: nil)
        wait(for: [sidebarGone], timeout: 10)
        assertListBesidePlayer(detail("dashboard"))
    }

    // MARK: - The player column

    @MainActor func testNowPlayingCanBeHiddenAndShown() throws {
        try launch(.portrait)
        tap(app.buttons["Hide Now Playing"])
        XCTAssertTrue(playerTitle.waitForNonExistence(timeout: 5), "The player should hide")
        tap(app.buttons["Show Now Playing"])
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 5), "The player should come back")
    }

    @MainActor func testTappingASongPlaysItInThePlayer() throws {
        try launch(.portrait)
        openOverplayFromDashboard()
        let song = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Teardrop'")).firstMatch
        // The songs start below the playlist's artwork; scroll the list to them.
        let listCentre = app.buttons["Shuffle and Play"].frame.midX / window.frame.width
        for _ in 0..<8 where !(song.exists && song.frame.maxY < window.frame.maxY) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: listCentre, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: listCentre, dy: 0.4)))
        }
        XCTAssertTrue(song.waitForExistence(timeout: 5), "The playlist should list Teardrop")
        tap(song)
        let playing = expectation(for: NSPredicate(format: "label == 'Teardrop'"), evaluatedWith: playerTitle)
        wait(for: [playing], timeout: 10)
    }
}
