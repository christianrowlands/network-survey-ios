import XCTest

/// Captures the Map, Lists, details, Settings and Files screens during a demo
/// survey. Runs only when SCREENSHOT_DIR is set (pass it to xcodebuild as
/// TEST_RUNNER_SCREENSHOT_DIR); SCREENSHOT_SUFFIX names the appearance.
final class DataScreensScreenshots: XCTestCase {
    private var directory: URL!
    private var suffix = ""

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR is not set")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suffix = environment["SCREENSHOT_SUFFIX"].map { "-\($0)" } ?? ""
        continueAfterFailure = true
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        let url = directory.appendingPathComponent("data-\(name)\(suffix).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    @MainActor
    func testCaptureDataScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoConnectDemo", "YES", "-NSDemoBoards", "2"]
        app.launch()
        let ble = app.buttons["survey.protocol.Bluetooth"]
        if ble.waitForExistence(timeout: 10) { ble.tap() }
        let start = app.buttons["survey.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: start)
        waitForExpectations(timeout: 15)
        start.tap()
        // Let the demo survey walk a while so lists, charts and the map fill in.
        sleep(40)

        let tabs = app.tabBars.firstMatch
        tabs.buttons["Lists"].tap()
        _ = app.cells.firstMatch.waitForExistence(timeout: 10)
        save(app, "lists-aps")
        app.cells.firstMatch.tap()
        _ = app.navigationBars["Access point"].waitForExistence(timeout: 5)
        save(app, "detail-ap")
        app.swipeUp()
        save(app, "detail-ap-2")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Clients"].tap()
        let connected = app.cells.containing(NSPredicate(format: "label CONTAINS 'Connected to'")).firstMatch
        _ = connected.waitForExistence(timeout: 10)
        save(app, "lists-clients")
        (connected.exists ? connected : app.cells.firstMatch).tap()
        _ = app.navigationBars["Client"].waitForExistence(timeout: 5)
        save(app, "detail-client")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Bluetooth"].tap()
        _ = app.cells.firstMatch.waitForExistence(timeout: 10)
        save(app, "lists-ble")
        app.cells.firstMatch.tap()
        _ = app.navigationBars["Bluetooth device"].waitForExistence(timeout: 5)
        save(app, "detail-ble")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        tabs.buttons["Map"].tap()
        sleep(3)
        save(app, "map")
        app.buttons["map.filter"].tap()
        app.buttons["map.zones"].tap()
        let map = app.otherElements["map.map"].exists ? app.otherElements["map.map"] : app.maps.firstMatch
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).press(forDuration: 1.0)
        _ = app.navigationBars["New privacy zone"].waitForExistence(timeout: 5)
        save(app, "zone-editor")
        if app.buttons["zone.add"].exists { app.buttons["zone.add"].tap() }
        sleep(1)
        save(app, "map-zones")
        if app.buttons["map.zonesDone"].exists { app.buttons["map.zonesDone"].tap() }

        tabs.buttons["Files"].tap()
        _ = app.staticTexts["Wi-Fi CSV"].waitForExistence(timeout: 10)
        save(app, "files")

        tabs.buttons["Settings"].tap()
        save(app, "settings")
        for (identifier, name) in [
            ("settings.mqtt", "settings-mqtt"), ("settings.grpc", "settings-grpc"),
            ("settings.nsAnalytics", "settings-nsanalytics"), ("settings.files", "settings-files"),
            ("settings.zones", "settings-zones"), ("settings.ignoreList", "settings-ignore"),
        ] {
            app.buttons[identifier].tap()
            sleep(1)
            save(app, name)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.swipeUp()
        app.buttons["Open-source licenses"].firstMatch.tap()
        sleep(1)
        save(app, "settings-licenses")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'GRDB'")).firstMatch.tap()
        sleep(1)
        save(app, "settings-license-text")
    }
}
