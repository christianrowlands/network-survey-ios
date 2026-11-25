import XCTest

/// The access point list grouped by SSID with the demo Scout, whose sites
/// often run one radio per band under the same name.
final class ListsGroupingTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAccessPointsGroupBySSID() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoStartSurvey", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Signals"].tap()

        // Grouped is the default.
        let grouping = app.segmentedControls["lists.apGrouping"]
        XCTAssertTrue(grouping.waitForExistence(timeout: 5))
        XCTAssertTrue(grouping.buttons["By SSID"].isSelected)

        let groups = app.buttons.matching(identifier: "lists.group")
        let pair = groups.matching(NSPredicate(format: "label CONTAINS ', 2 access points,'")).firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 40), "no network with two access points appeared")
        attach(app, "lists-grouped")

        // Opening the group shows its two access points under it.
        let ssid = String(pair.label.prefix { $0 != "," })
        let group = groups.matching(NSPredicate(format: "label BEGINSWITH %@", ssid + ",")).firstMatch
        group.tap()
        XCTAssertEqual(group.value as? String, "Expanded")
        let members = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != 'lists.group'", ssid + ","))
        XCTAssertTrue(members.element(boundBy: 1).waitForExistence(timeout: 5), "the group's access points are missing")
        attach(app, "lists-group-open")
        members.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Closing it hides them again.
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        XCTAssertEqual(group.value as? String, "Collapsed")
        XCTAssertFalse(members.firstMatch.exists)

        // By BSSID is one row per access point.
        grouping.buttons["By BSSID"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: groups.firstMatch)
        wait(for: [gone], timeout: 10)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS 'dBm'")).firstMatch.waitForExistence(timeout: 10))
        attach(app, "lists-flat")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
