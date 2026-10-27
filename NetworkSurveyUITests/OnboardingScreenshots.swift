import XCTest

/// Screenshots of the welcome, the NS Scout guide, the NS Analytics intro and
/// About, kept as test attachments for design review. Run once per appearance
/// (`xcrun simctl ui <device> appearance dark`).
final class OnboardingScreenshots: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureOnboardingScreens() {
        let mode = UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"

        // The welcome, then the Scout guide from it.
        var app = launch(["-NSShowWelcome", "YES"])
        XCTAssertTrue(app.buttons["welcome.next"].waitForExistence(timeout: 10))
        shot(app, "welcome-intro-\(mode)")
        app.buttons["welcome.next"].tap()
        XCTAssertTrue(app.buttons["welcome.haveScout"].waitForExistence(timeout: 5))
        shot(app, "welcome-scout-\(mode)")
        app.buttons["How to get one"].tap()
        let next = app.buttons["scoutGuide.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        for page in ["get", "install", "pair", "demo"] {
            sleep(1)
            shot(app, "scout-guide-\(page)-\(mode)")
            if page != "demo" { next.tap() }
        }
        next.tap()  // Done closes the guide; the welcome stays until a choice is made.
        XCTAssertTrue(app.buttons["welcome.haveScout"].waitForExistence(timeout: 5))

        // The Survey screen with the brand title, nothing connected.
        app = launch([])
        XCTAssertTrue(app.buttons["survey.start"].waitForExistence(timeout: 10))
        sleep(1)
        shot(app, "survey-branded-\(mode)")

        // The Scouts screen with no Scout yet.
        app = launch(["-NSOpenScreen", "boards"])
        XCTAssertTrue(app.buttons["boards.guide"].waitForExistence(timeout: 10))
        shot(app, "scouts-empty-\(mode)")
        app.buttons["boards.guide"].tap()
        XCTAssertTrue(app.buttons["scoutGuide.next"].waitForExistence(timeout: 5))
        sleep(1)
        shot(app, "scout-guide-meet-\(mode)")

        // NS Analytics before registering, and About.
        app = launch([])
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.nsAnalytics"].tap()
        XCTAssertTrue(app.buttons["nsa.scan"].waitForExistence(timeout: 5))
        shot(app, "nsa-intro-\(mode)")
        app.swipeUp()
        sleep(1)
        shot(app, "nsa-intro-bottom-\(mode)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp()
        app.staticTexts["About"].firstMatch.tap()
        sleep(1)
        shot(app, "about-\(mode)")
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
