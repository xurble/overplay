import XCTest

/// The iPhone's full-screen player, on the simulator build with its sample
/// library and simulated player (`-OverplayUITesting`).
final class IPhonePlayerUITests: XCTestCase {
    @MainActor private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A swipe down that starts on Pause closes the player and leaves the
    /// music playing: the button is never pressed. (Before the UIKit pan, the
    /// swipe did not even close the player from a button here.)
    @MainActor func testSwipeDownFromAButtonClosesWithoutPressingIt() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The full-screen player is the iPhone's.")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-OverplayUITesting"]
        app.launch()

        let play = app.buttons["Play Overplay"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "The dashboard should offer to play Overplay")
        play.tap()
        let miniPlayer = element("mini-player")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10), "Playing should show the mini player")
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()

        let title = element("now-playing-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The full player should open")
        // The full player's Pause: the lowest one on screen, below its art.
        let pauses = app.buttons.matching(identifier: "Pause").allElementsBoundByIndex.filter { $0.frame.minY > title.frame.maxY }
        let pause = try XCTUnwrap(pauses.first, "The full player should show Pause while playing")

        let start = pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 420))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)

        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "The swipe should close the player")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3), "The music should still be playing: Pause was not pressed")
        XCTAssertFalse(app.buttons["Play"].exists, "Pause should not have been pressed")
    }
}
