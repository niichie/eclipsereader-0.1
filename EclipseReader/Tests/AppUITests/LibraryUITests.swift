import XCTest

final class LibraryUITests: XCTestCase {
    @MainActor
    func testReaderFitsAtLaunchAndPreservesPageWhileRotating() {
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        for (pose, style) in [(UIDeviceOrientation.landscapeLeft, "--slide"), (.landscapeRight, "--curl")] {
            device.orientation = pose
            app.launchArguments = ["--reader-regression", style]
            app.launch()
            let counter = app.staticTexts["logicalPage"]
            XCTAssertTrue(counter.waitForExistence(timeout: 15))
            let first = app.descendants(matching: .any)["art-0"].firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            let art = first.frame
            XCTAssertGreaterThan(art.width, 2)
            XCTAssertGreaterThan(art.height, 2)
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(window.insetBy(dx: -2, dy: -2).contains(first.frame))
            let second = app.descendants(matching: .any)["art-1"].firstMatch
            if second.exists && window.contains(second.frame) && second.frame.width > 2 {
                XCTAssertGreaterThan(first.frame.midX, second.frame.midX)
                XCTAssertEqual(first.frame.minX, second.frame.maxX, accuracy: 2)
            }
            let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let from = center.withOffset(CGVector(dx: window.width * 0.28, dy: 0))
            let to = center.withOffset(CGVector(dx: -window.width * 0.28, dy: 0))
            // The manga fixture uses the default rightward swipe to advance.
            to.press(forDuration: 0.03, thenDragTo: from)
            let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Page 1 of 8"), object: counter)
            XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
            let landed = counter.label
            XCTAssertTrue(["Page 2 of 8", "Page 3 of 8"].contains(landed))
            device.orientation = .portrait
            XCTAssertEqual(counter.label, landed)
            let snapshot = XCTAttachment(screenshot: app.screenshot())
            snapshot.name = "Reader after rotation \(style)"
            snapshot.lifetime = .keepAlways
            add(snapshot)
            app.terminate()
        }
    }
    @MainActor
    func testLibraryAndSettingsSurviveRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--demo-library"] // Disables automatic network refresh, never changes source data.
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["chapterBrowser"].waitForExistence(timeout: 10))
        // The phone tab bar sits along the bottom in both orientations.
        let settingsTab = tab("Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(settingsTab.frame.midY, app.windows.firstMatch.frame.height * 0.8)
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeTab = tab("Settings", in: app)
        XCTAssertGreaterThan(landscapeTab.frame.midY, app.windows.firstMatch.frame.height * 0.75)
        let storage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Storage")).firstMatch
        for _ in 0..<6 {
            if storage.exists && storage.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(storage.exists && storage.isHittable)
        storage.tap()
        let clearCache = app.buttons["Clear temporary images"]
        XCTAssertTrue(clearCache.waitForExistence(timeout: 5) && clearCache.isHittable)
        XCUIDevice.shared.orientation = .portrait
        tab("Library", in: app).tap()
        XCTAssertTrue(app.buttons["chapterBrowser"].waitForExistence(timeout: 5))
        // Opening the series covers the library with its page.
        app.buttons["chapterBrowser"].tap()
        let covered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"), object: app.buttons["chapterBrowser"])
        XCTAssertEqual(XCTWaiter.wait(for: [covered], timeout: 5), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["chapterBrowser"].waitForExistence(timeout: 5))
    }
    @MainActor
    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let phone = app.buttons["tab-\(name)"]
        return phone.exists ? phone : app.tabBars.buttons[name]
    }
}
