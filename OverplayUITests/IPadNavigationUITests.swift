import XCTest

/// Navigation in the regular-width (iPad) layout, which matches an open
/// folding phone: list and player in halves, side by side in landscape and
/// player above list in portrait, with the sidebar sliding over the list. Runs the simulator build with a
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
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The halves layout is for regular width.")
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
        XCTAssertEqual(list.frame.width / window.frame.width, 0.5, accuracy: 0.02, "The list should take half", file: file, line: line)
    }

    @MainActor
    private func assertPlayerAboveList(_ list: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The list should exist", file: file, line: line)
        XCTAssertTrue(isOnScreen(playerTitle), "The player should be on screen", file: file, line: line)
        XCTAssertLessThanOrEqual(playerTitle.frame.maxY, list.frame.minY, "The player should be above the list, not over it", file: file, line: line)
        XCTAssertGreaterThanOrEqual(list.frame.minY, window.frame.height * 0.48, "The list should take the lower half", file: file, line: line)
    }

    /// The sidebar slides over the list without shrinking it, and closes
    /// after a choice.
    @MainActor private func chooseFromSidebar(_ item: String, file: StaticString = #filePath, line: UInt = #line) {
        let showSidebar = app.buttons["Show Sidebar"]
        XCTAssertTrue(showSidebar.waitForExistence(timeout: 10), "There should be a Show Sidebar button", file: file, line: line)
        tap(showSidebar)
        let listWidth = detail("dashboard").frame.width
        let opened = expectation(for: NSPredicate { _, _ in self.isOnScreen(self.sidebar(item)) }, evaluatedWith: nil)
        wait(for: [opened], timeout: 5)
        XCTAssertEqual(detail("dashboard").frame.width, listWidth, accuracy: 1, "The sidebar should slide over the list, not shrink it", file: file, line: line)
        tap(sidebar(item))
        let closed = expectation(for: NSPredicate { _, _ in !self.isOnScreen(self.sidebar(item)) }, evaluatedWith: nil)
        wait(for: [closed], timeout: 5)
    }

    @MainActor private func openOverplayFromDashboard() {
        let row = detail("dashboard").buttons.matching(NSPredicate(format: "label BEGINSWITH 'Overplay'")).firstMatch
        // The first launch after an install can take a while to fill the list.
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The dashboard should list Overplay")
        tap(row)
        XCTAssertTrue(app.buttons["Shuffle and Play"].waitForExistence(timeout: 10), "The Overplay playlist should open")
    }

    // MARK: - Landscape: list and player side by side in halves, as an open folding phone

    @MainActor func testLandscapeSplitsListAndPlayerInHalves() throws {
        try launch(.landscapeLeft)
        XCTAssertFalse(isOnScreen(sidebar("dashboard")), "The sidebar should start hidden")
        assertListBesidePlayer(detail("dashboard"))
    }

    @MainActor func testLandscapeSidebarOpensOverTheListAndClosesAfterAChoice() throws {
        try launch(.landscapeLeft)
        chooseFromSidebar("retired")
        assertListBesidePlayer(detail("retired"))
    }

    @MainActor func testLandscapeDashboardOpensAPlaylistBesideThePlayer() throws {
        try launch(.landscapeLeft)
        openOverplayFromDashboard()
        XCTAssertTrue(isOnScreen(playerTitle), "The player should stay beside the opened playlist")
        XCTAssertLessThanOrEqual(app.buttons["Shuffle and Play"].frame.maxX, playerTitle.frame.minX)
    }

    // MARK: - Portrait: player above the list in halves, as an open folding phone

    @MainActor func testPortraitStacksPlayerAboveList() throws {
        try launch(.portrait)
        XCTAssertFalse(isOnScreen(sidebar("dashboard")), "The sidebar should start hidden")
        assertPlayerAboveList(detail("dashboard"))
    }

    @MainActor func testPortraitSidebarOpensOverTheListAndClosesAfterAChoice() throws {
        try launch(.portrait)
        chooseFromSidebar("retired")
        assertPlayerAboveList(detail("retired"))
    }

    @MainActor func testPortraitDashboardOpensAPlaylistBelowThePlayer() throws {
        try launch(.portrait)
        openOverplayFromDashboard()
        XCTAssertTrue(isOnScreen(playerTitle), "The player should stay above the opened playlist")
        XCTAssertLessThanOrEqual(playerTitle.frame.maxY, app.buttons["Shuffle and Play"].frame.minY)
    }

    @MainActor func testRotatingBetweenPortraitAndLandscapeKeepsTheLayoutRight() throws {
        try launch(.portrait)
        assertPlayerAboveList(detail("dashboard"))
        try rotate(to: .landscapeLeft)
        let beside = expectation(for: NSPredicate { _, _ in self.detail("dashboard").frame.maxX <= self.playerTitle.frame.minX }, evaluatedWith: nil)
        wait(for: [beside], timeout: 10)
        assertListBesidePlayer(detail("dashboard"))
        try rotate(to: .portrait)
        let above = expectation(for: NSPredicate { _, _ in self.playerTitle.frame.maxY <= self.detail("dashboard").frame.minY }, evaluatedWith: nil)
        wait(for: [above], timeout: 10)
        assertPlayerAboveList(detail("dashboard"))
    }

    // MARK: - The player

    @MainActor func testNowPlayingKeepsItsHalf() throws {
        try launch(.portrait)
        XCTAssertFalse(app.buttons["Hide Now Playing"].exists, "The player keeps its half and cannot be hidden")
    }

    @MainActor func testTappingASongPlaysItInThePlayer() throws {
        try launch(.portrait)
        openOverplayFromDashboard()
        let song = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Teardrop'")).firstMatch
        // The songs start below the playlist's artwork; scroll the list to them.
        let listCentre = app.buttons["Shuffle and Play"].frame.midX / window.frame.width
        for _ in 0..<8 where !(song.exists && song.frame.maxY < window.frame.maxY) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: listCentre, dy: 0.9))
            start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: listCentre, dy: 0.6)))
        }
        XCTAssertTrue(song.waitForExistence(timeout: 5), "The playlist should list Teardrop")
        tap(song)
        let playing = expectation(for: NSPredicate(format: "label == 'Teardrop'"), evaluatedWith: playerTitle)
        wait(for: [playing], timeout: 10)
    }
}
