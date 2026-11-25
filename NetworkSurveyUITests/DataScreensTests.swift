import XCTest

/// Smoke flows for the Map, Lists, details, Settings and Files with the demo
/// board. Each launch is isolated (in-memory settings and database).
final class DataScreensTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launchSurveying(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES", "-NSAutoStartSurvey", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testListsSearchDetailAndIgnore() {
        let app = launchSurveying()
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        app.buttons["By BSSID"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Net")
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'Net'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no access point matched the search")
        row.tap()

        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["BSSID"].waitForExistence(timeout: 5))
        app.buttons["detail.ignore"].tap()
        let ignore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ignore this access point'")).firstMatch
        XCTAssertTrue(ignore.waitForExistence(timeout: 5))
        ignore.tap()
        XCTAssertTrue(app.alerts["Added to the ignore list"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()

        app.tabBars.buttons["Settings"].tap()
        let ignoreRow = app.buttons["settings.ignoreList"]
        XCTAssertTrue(ignoreRow.waitForExistence(timeout: 5))
        ignoreRow.tap()
        XCTAssertTrue(app.navigationBars["Ignore list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Access points (BSSID)"].exists)
    }

    /// The survey's counts open the matching list, and probe requests drill
    /// in by network and by client.
    @MainActor
    func testSurveyCountsOpenListsAndProbes() {
        let app = launchSurveying()
        let probes = app.buttons["survey.count.Probe requests"]
        XCTAssertTrue(probes.waitForExistence(timeout: 15))
        probes.tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Probes"].isSelected)

        let byNetwork = NSPredicate(format: "label CONTAINS ' client' AND NOT (label BEGINSWITH 'Any network')")
        let network = app.cells.containing(byNetwork).firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 30), "no probed network appeared")
        network.tap()
        XCTAssertTrue(app.navigationBars["Probed network"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Clients that looked for it"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["By client"].tap()
        let client = app.cells.containing(NSPredicate(format: "label CONTAINS 'Looked for'")).firstMatch
        XCTAssertTrue(client.waitForExistence(timeout: 10), "no probing client appeared")
        client.tap()
        XCTAssertTrue(app.navigationBars["Client"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Networks it looked for"].waitForExistence(timeout: 5))

        // Another count closes the open detail and shows its list.
        app.tabBars.buttons["Survey"].tap()
        let aps = app.buttons["survey.count.Wi-Fi APs"]
        XCTAssertTrue(aps.waitForExistence(timeout: 5))
        aps.tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["APs"].isSelected)
        XCTAssertFalse(app.segmentedControls["lists.probeGrouping"].exists)
    }

    @MainActor
    func testMQTTSettingsSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settings.mqtt"].tap()
        XCTAssertTrue(app.navigationBars["MQTT"].waitForExistence(timeout: 5))

        app.switches["mqtt.enabled"].switches.firstMatch.tap()
        let host = app.textFields["mqtt.host"]
        host.tap()
        host.typeText("broker.example.com")
        let port = app.textFields["mqtt.port"]
        port.tap()
        port.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        port.typeText(XCUIKeyboardKey.delete.rawValue + "1883")
        app.textFields["mqtt.username"].tap()
        app.textFields["mqtt.username"].typeText("surveyor")

        app.navigationBars["MQTT"].buttons.element(boundBy: 0).tap()
        let row = app.buttons["settings.mqtt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.staticTexts["broker.example.com"].exists, "Settings row should show the saved host")

        row.tap()
        XCTAssertEqual(app.textFields["mqtt.host"].value as? String, "broker.example.com")
        XCTAssertEqual(app.textFields["mqtt.port"].value as? String, "1883")
        XCTAssertEqual(app.textFields["mqtt.username"].value as? String, "surveyor")
    }

    /// Files opens from the survey title menu on Signals, as a sheet, with
    /// the running survey's files and the file options above them.
    @MainActor
    func testFilesShowSessionAfterDemoSurvey() {
        let app = launchSurveying()
        app.tabBars.buttons["Signals"].tap()
        let title = app.buttons["session.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        let files = app.buttons["session.files"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        // It shows just this survey, with the file options above it.
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 10))
        let enabled = app.switches["files.enabled"]
        for _ in 0..<3 where !enabled.exists { app.collectionViews["files.list"].swipeDown() }
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), "file options sit above the folders")
        let wifiCSV = app.staticTexts["Wi-Fi CSV"]
        XCTAssertTrue(wifiCSV.waitForExistence(timeout: 20), "the running survey's Wi-Fi CSV should be listed")
        XCTAssertTrue(app.staticTexts["Recording"].exists)
        app.buttons["files.done"].tap()
        XCTAssertTrue(app.navigationBars["Signals"].waitForExistence(timeout: 5))
    }

    /// A probed network can go on the watchlist. (The Manufacturer link is
    /// not testable with the demo: its addresses are in the documentation
    /// range, which has no maker.)
    @MainActor
    func testProbedNetworkCanGoOnWatchlist() {
        let app = launchSurveying()
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.buttons["Probes"].waitForExistence(timeout: 5))
        app.buttons["Probes"].tap()
        // A row's own label, not a cell's: a cell "contains" any descendant
        // that lacks the words, so it would match the wildcard row too.
        let probed = app.buttons.matching(NSPredicate(
            format: "label CONTAINS ' client' AND label CONTAINS ' request' AND NOT label CONTAINS[c] 'wildcard'"
        )).firstMatch
        XCTAssertTrue(probed.waitForExistence(timeout: 20), "no probed network")
        probed.tap()
        XCTAssertTrue(app.navigationBars["Probed network"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["watchlist.addFromDetail"].waitForExistence(timeout: 5))
        attach(app, "probed-network-watchlist")
    }

    /// After Stop, Survey offers the survey's files to share and see.
    @MainActor
    func testShareFilesAfterStop() {
        let app = launchSurveying()
        app.tabBars.buttons["Survey"].tap()
        let stop = app.buttons["survey.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        sleep(3)
        stop.tap()
        app.buttons["survey.confirmStop"].firstMatch.tap()
        let share = app.buttons["survey.shareFiles"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "Share files should appear once the survey stops")
        attach(app, "survey-finished")
        app.buttons["survey.seeFiles"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wi-Fi CSV"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["survey.closeFinished"].tap()
        XCTAssertFalse(share.waitForExistence(timeout: 2))
    }

    /// The zone added on the map is the setting the survey pipeline reads
    /// (Settings > Privacy zones lists `Settings.privacyZones`).
    @MainActor
    func testPrivacyZoneAddedOnMapIsSaved() {
        let app = launchSurveying()
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.buttons["map.filter"].waitForExistence(timeout: 5))
        // The menu can open late; retry until the zone editing banner shows.
        let zonesDone = app.buttons["map.zonesDone"]
        for _ in 0..<3 where !zonesDone.exists {
            app.buttons["map.filter"].tap()
            let zones = app.buttons["map.zones"]
            if zones.waitForExistence(timeout: 3) { zones.tap() }
            _ = zonesDone.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(zonesDone.exists, "zone editing should start")
        let map = app.otherElements["map.map"].exists ? app.otherElements["map.map"] : app.maps.firstMatch
        // Off center: the demo track and its markers sit in the middle.
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7)).press(forDuration: 1.0)
        XCTAssertTrue(app.navigationBars["New privacy zone"].waitForExistence(timeout: 5))
        app.buttons["zone.add"].tap()
        app.buttons["map.zonesDone"].tap()

        app.tabBars.buttons["Settings"].tap()
        let zones = app.buttons["settings.zones"]
        XCTAssertTrue(zones.waitForExistence(timeout: 5))
        XCTAssertTrue(zones.staticTexts["1"].exists, "Settings should count one privacy zone")
        zones.tap()
        XCTAssertTrue(app.staticTexts["Zone 1"].waitForExistence(timeout: 5))
    }

    /// Between surveys Lists show nothing until a past survey is picked, and
    /// a past survey says so.
    @MainActor
    func testListsShowPastSurveyOnlyWhenPicked() {
        let app = launchSurveying()
        let stop = app.buttons["survey.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        app.tabBars.buttons["Signals"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20), "no rows while recording")
        XCTAssertFalse(app.descendants(matching: .any)["pastSurvey.bar"].exists)

        app.tabBars.buttons["Survey"].tap()
        stop.tap()
        app.buttons["survey.confirmStop"].firstMatch.tap()
        XCTAssertTrue(app.buttons["survey.start"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Signals"].tap()
        let showLast = app.buttons["noSurvey.showLast"]
        XCTAssertTrue(showLast.waitForExistence(timeout: 5), "a stopped survey should not stay on Lists")
        XCTAssertTrue(app.staticTexts["Not recording"].exists)
        showLast.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pastSurvey.bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10), "the past survey's rows are missing")

        app.buttons["pastSurvey.close"].tap()
        XCTAssertTrue(showLast.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["pastSurvey.bar"].exists)
    }

    @MainActor
    func testMapShowsMarkers() {
        let app = launchSurveying()
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 5))
        let marker = app.buttons.matching(NSPredicate(format: "label CONTAINS 'strongest' OR label BEGINSWITH 'Group of'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 30), "map should show markers for the demo survey")
    }

    /// The demo's access points use the documentation range, so neither
    /// rows nor details name a maker for them (not IANA, which owns the block).
    @MainActor
    func testDocumentationAddressesHaveNoManufacturer() {
        let app = launchSurveying()
        app.tabBars.buttons["Signals"].tap()
        app.buttons["By BSSID"].tap()
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS '00:00:5E:00:53'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertFalse(app.cells.containing(NSPredicate(format: "label CONTAINS 'IANA'")).firstMatch.exists,
                       "a documentation address has no maker")
        attach(app, "lists-aps")
        row.tap()
        XCTAssertTrue(app.navigationBars["Access point"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["detail.manufacturer"].exists)
    }

    /// The OUI lookup in Tools names the manufacturer from the registry
    /// built into the app, and explains a randomized address.
    @MainActor
    func testOUILookupNamesManufacturer() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Tools"].tap()
        let row = app.buttons["tools.ouiLookup"]
        if !row.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["OUI lookup"].waitForExistence(timeout: 5))
        let field = app.textFields["oui.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("00:00:00:12:34:56")
        XCTAssertTrue(app.staticTexts["XEROX CORPORATION"].waitForExistence(timeout: 5))
        attach(app, "oui-vendor")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'MA-L'")).firstMatch.exists)

        field.clearAndType("DA:A1:19:00:00:01")
        XCTAssertTrue(app.staticTexts["Randomized address"].waitForExistence(timeout: 5))
        attach(app, "oui-randomized")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAppearanceSwitchesLive() {
        let app = XCUIApplication()
        app.launchArguments = ["-NSUITesting", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        choose("Midnight", in: app)
        XCTAssertEqual(groundColor(app), 0x060B1A, "Midnight ground")
        choose("Dark", in: app)
        XCTAssertEqual(groundColor(app), 0x0E1116, "dark ground")
        choose("Light", in: app)
        XCTAssertEqual(groundColor(app), 0xF2F4F7, "light ground")
    }

    @MainActor
    private func choose(_ option: String, in app: XCUIApplication) {
        let picker = app.buttons["settings.appearance"]
        for _ in 0..<3 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(option) option")
        item.tap()
        _ = app.buttons[option].waitForNonExistence(timeout: 2)
    }

    /// The Settings ground left of the list rows, as 0xRRGGBB.
    @MainActor
    private func groundColor(_ app: XCUIApplication) -> UInt32 {
        guard let image = app.screenshot().image.cgImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: -4, y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
        return UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
    }
}

extension XCUIElement {
    /// Replaces the text field's contents.
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
