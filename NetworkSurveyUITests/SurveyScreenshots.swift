import XCTest

/// Screenshots of the Survey and Boards screens and the Live Activity, kept as
/// test attachments (for design review, not assertions). Run once per
/// appearance (`xcrun simctl ui <device> appearance dark`).
final class SurveyScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureSurveyScreens() {
        capture(UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light")
    }

    @MainActor
    private func capture(_ mode: String) {
        // Ready, nothing connected.
        var app = launch([])
        XCTAssertTrue(app.buttons["survey.start"].waitForExistence(timeout: 10))
        shot(app, "survey-ready-\(mode)")
        app.swipeUp()
        shot(app, "survey-ready-bottom-\(mode)")

        // Boards with two demo boards nearby, then one connected.
        app = launch(["-NSDemoBoards", "2", "-NSOpenScreen", "boards"])
        XCTAssertTrue(app.buttons.matching(identifier: "boards.nearby").firstMatch.waitForExistence(timeout: 10))
        shot(app, "survey-boards-nearby-\(mode)")
        app.buttons.matching(identifier: "boards.nearby").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "boards.yours").firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "survey-boards-connected-\(mode)")

        // Board detail with the role picker.
        app = launch(["-NSAutoConnectDemo", "YES", "-NSOpenScreen", "board"])
        XCTAssertTrue(app.staticTexts["board.connection"].waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "survey-board-detail-\(mode)")
        app.swipeUp()
        shot(app, "survey-board-detail-bottom-\(mode)")

        // Ready with a board connected.
        app = launch(["-NSDemoBoards", "2", "-NSAutoConnectDemo", "YES"])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "survey.boardChip").firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "survey-ready-connected-\(mode)")

        // Recording with two demo boards.
        app = launch(["-NSDemoBoards", "2", "-NSAutoStartSurvey", "YES"])
        XCTAssertTrue(app.buttons["survey.stop"].waitForExistence(timeout: 15))
        sleep(8)
        shot(app, "survey-recording-\(mode)")
        app.swipeUp()
        sleep(1)
        shot(app, "survey-recording-bottom-\(mode)")
        app.descendants(matching: .any).matching(identifier: "survey.boardChip").firstMatch.tap()
        sleep(1)
        shot(app, "survey-role-sheet-\(mode)")
        app.buttons["Done"].tap()
        app.buttons["survey.stop"].tap()
        sleep(1)
        shot(app, "survey-stop-confirm-\(mode)")

        app.terminate()

        // Screenshots cannot show the real Live Activity; the app draws the same views.
        app = launch(["-NSOpenScreen", "liveActivity"])
        XCTAssertTrue(app.navigationBars["Live Activity"].waitForExistence(timeout: 10))
        shot(app, "survey-live-activity-\(mode)")
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
