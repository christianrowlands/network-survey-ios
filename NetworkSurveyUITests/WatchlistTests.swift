import XCTest

/// The Wi-Fi watchlist with the demo Scout: add a network from its details,
/// see it marked as watched, and find its sighting in History.
final class WatchlistTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Notifications") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
    }

    @MainActor
    func testAddFromDetailMarksAndRecordsSighting() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoStartSurvey", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))

        app.tabBars.buttons["Lists"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Net")
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'Net'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no access point matched the search")
        row.tap()
        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))

        let add = app.buttons["watchlist.addFromDetail"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["Add to watchlist"].waitForExistence(timeout: 5))
        attach(app, "watchlist-add-sheet")
        app.buttons["watchlist.save"].tap()

        // The first network added is when the app asks to send notifications;
        // the interruption monitor answers Allow.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5), "adding closes the form")
        XCTAssertTrue(app.descendants(matching: .any)["watchlist.watched"].waitForExistence(timeout: 5),
                      "the detail should mark the access point as watched")
        let onWatchlist = app.buttons["watchlist.onWatchlist"]
        XCTAssertTrue(onWatchlist.waitForExistence(timeout: 5))
        attach(app, "watchlist-detail-watched")

        // The list row is marked too.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let watchedRow = app.cells.containing(NSPredicate(format: "label CONTAINS 'On watchlist'")).firstMatch
        XCTAssertTrue(watchedRow.waitForExistence(timeout: 5), "the list row should be marked as watched")
        attach(app, "watchlist-list-marker")

        // The demo Scout keeps hearing it: a sighting is recorded and notified.
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'is nearby'")).firstMatch
        if banner.waitForExistence(timeout: 30) {
            attach(springboard, "watchlist-notification")
            banner.tap()
        } else {
            app.tabBars.buttons["Settings"].tap()
            openWatchlist(app)
            app.buttons["watchlist.history"].tap()
        }
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        let group = app.cells.containing(NSPredicate(format: "label CONTAINS '1 sighting, matched by name'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30), "History should list the sighting")
        attach(app, "watchlist-history")

        group.tap()
        XCTAssertTrue(app.navigationBars["Watched network"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sightings (1)"].waitForExistence(timeout: 5))
        attach(app, "watchlist-entry-sightings")

        // Back on the Watchlist screen the network shows it was seen.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Watchlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS 'Seen once'")).firstMatch.waitForExistence(timeout: 5))
        attach(app, "watchlist-screen")
    }

    /// Adding by hand from the Watchlist screen, editing and removing.
    @MainActor
    func testAddEditRemoveByHand() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        openWatchlist(app)
        attach(app, "watchlist-empty")

        app.buttons["watchlist.add"].tap()
        XCTAssertTrue(app.navigationBars["Add to watchlist"].waitForExistence(timeout: 5))
        app.buttons["Access point"].tap()
        let bssid = app.textFields["watchlist.bssid"]
        bssid.tap()
        bssid.typeText("02-00-5E-00-53-01")
        app.textFields["watchlist.label"].tap()
        app.textFields["watchlist.label"].typeText("Lobby AP")
        app.buttons["watchlist.save"].tap()

        let entry = app.cells.containing(NSPredicate(
            format: "label CONTAINS 'Lobby AP' AND label CONTAINS '02:00:5e:00:53:01' AND label CONTAINS 'Not seen yet'"
        )).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        attach(app, "watchlist-one-entry")

        entry.tap()
        XCTAssertTrue(app.navigationBars["Watched network"].waitForExistence(timeout: 5))
        app.buttons["watchlist.edit"].tap()
        let label = app.textFields["watchlist.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.clearAndType("Front desk")
        app.buttons["watchlist.save"].tap()
        XCTAssertTrue(app.staticTexts["Front desk"].waitForExistence(timeout: 5))

        app.buttons["watchlist.remove"].tap()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Watchlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No watched networks"].waitForExistence(timeout: 5))
    }

    /// A pasted share link (the example from the link format page) is
    /// previewed, then imported; importing it again finds nothing new.
    @MainActor
    func testImportFromPastedLink() {
        let link = "https://networksurvey.app/app/watchlist?d=eyJ2IjoxLCJuYW1lIjoiQWNtZSBuZXR3b3JrcyIsImVudHJpZXMiOlt7ImxhYmVsIjoiSFEiLCJzc2lkIjoiSFEtR3Vlc3QifSx7ImxhYmVsIjoiTG9iYnkiLCJic3NpZCI6ImE0OjExOjIyOjMzOjQ0OjFjIn1dfQ"
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        openWatchlist(app)

        for round in 0..<2 {
            app.buttons["watchlist.more"].tap()
            app.buttons["watchlist.import"].tap()
            let text = app.textViews["watchlist.importText"].exists ? app.textViews["watchlist.importText"] : app.textFields["watchlist.importText"]
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            text.tap()
            text.typeText(link)
            app.buttons["watchlist.importNext"].tap()
            if round == 0 {
                XCTAssertTrue(app.staticTexts["Add \u{201C}Acme networks\u{201D}?"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["From a link: 2 new networks."].exists)
                attach(app, "watchlist-import-preview")
                app.buttons["watchlist.importConfirm"].tap()
            } else {
                XCTAssertTrue(app.staticTexts["All 2 networks in this link are already on your watchlist."].waitForExistence(timeout: 5))
                attach(app, "watchlist-import-all-saved")
                app.buttons["Done"].tap()
            }
            XCTAssertTrue(app.navigationBars["Watchlist"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS 'Lobby' AND label CONTAINS 'a4:11:22:33:44:1c'")).firstMatch.exists)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label CONTAINS 'HQ' AND label CONTAINS 'HQ-Guest'")).firstMatch.exists)
        XCTAssertEqual(app.switches["watchlist.alerts"].value as? String, "1", "importing turns alerts on")
        attach(app, "watchlist-imported")
    }

    /// Settings > Watchlist, scrolling down to Tools.
    @MainActor
    private func openWatchlist(_ app: XCUIApplication) {
        let row = app.buttons["settings.watchlist"]
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Watchlist"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
