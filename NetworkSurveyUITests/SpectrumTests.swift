import XCTest

/// The Wi-Fi spectrum with the demo board: opened from the access point
/// list, switched between bands, and into an access point's detail.
final class SpectrumTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSpectrumBandsAndDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoStartSurvey", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Lists"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "no access point appeared")

        app.buttons["lists.spectrum"].tap()
        XCTAssertTrue(app.navigationBars["Wi-Fi spectrum"].waitForExistence(timeout: 5))
        let chart = app.otherElements["spectrum.chart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        XCTAssertEqual(chart.label, "2.4 GHz spectrum")
        // Let the demo survey hear more networks before the screenshot.
        let busy = NSPredicate(format: "value CONTAINS 'access points.'")
        expectation(for: busy, evaluatedWith: chart)
        waitForExpectations(timeout: 30)
        sleep(5)
        attach("spectrum-2.4")

        app.buttons["5 GHz"].tap()
        XCTAssertTrue(app.segmentedControls["spectrum.channels"].waitForExistence(timeout: 5))
        XCTAssertTrue(chart.label.hasPrefix("5 GHz, channels"), "the 5 GHz chart should be shown, not \(chart.label)")
        sleep(2)
        attach("spectrum-5")
        for range in ["100 to 144", "149 to 177", "36 to 64"] {
            app.buttons[range].tap()
            XCTAssertEqual(chart.label, "5 GHz, channels \(range) spectrum")
        }

        // A row under the chart opens the access point.
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'Channel '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the 5 GHz chart should list access points")
        row.tap()
        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BSSID"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // So does a tap on a curve: the bottom of the chart, under the busiest 2.4 GHz channels.
        app.buttons["2.4 GHz"].tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let plotted = [0.25, 0.45, 0.65, 0.85].contains { dx in
            chart.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.8)).tap()
            return app.navigationBars["Access point"].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(plotted, "a tap on the chart should open an access point")
    }
}
