import XCTest

/// Walks every main screen with an offline demo library and saves a screenshot of each,
/// in portrait and landscape. CI runs it on small and large iPhones, iPads and the Duo,
/// then publishes the pictures so layouts can be checked on every screen shape.
final class ScreenTourUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor
    func testTourPortrait() { tour(.portrait, tag: "portrait") }

    @MainActor
    func testTourLandscape() { tour(.landscapeLeft, tag: "landscape") }

    @MainActor
    private func tour(_ orientation: UIDeviceOrientation, tag: String) {
        let device = XCUIDevice.shared
        device.orientation = orientation
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-library", "--ui-testing"]
        app.launch()
        settle()
        shot(app, "\(tag) 01 library")

        // Library scrolled to the grid.
        app.swipeUp(); settle(0.8)
        shot(app, "\(tag) 02 library grid")
        app.swipeDown(); app.swipeDown(); settle(0.5)

        // Series page.
        let card = app.buttons.matching(identifier: "series-Moonlit Blade").firstMatch
        if scrollTo(card, in: app) {
            card.tap(); settle(1.5)
            shot(app, "\(tag) 03 series")
            app.swipeUp(); settle(0.6)
            shot(app, "\(tag) 04 series chapters")
            app.swipeDown(); settle(0.4)

            // Reader (manga, paged) with controls, then clean.
            let resume = app.buttons["seriesContinue"].firstMatch
            if resume.waitForExistence(timeout: 4) {
                resume.tap(); settle(1.2)
                shot(app, "\(tag) 05 reader controls")
                settle(2.5)
                shot(app, "\(tag) 06 reader page")
                tapCenter(app); settle(0.6)
                closeReader(app)
            }
            goBack(app)
        }

        // Manhwa reader (vertical strips).
        let manhwa = app.buttons.matching(identifier: "series-Step by Step").firstMatch
        if scrollTo(manhwa, in: app) {
            manhwa.tap(); settle(1.2)
            let resume = app.buttons["seriesContinue"].firstMatch
            if resume.waitForExistence(timeout: 4) {
                resume.tap(); settle(3.5)
                app.swipeUp(); settle(1)
                shot(app, "\(tag) 07 manhwa strips")
                tapCenter(app); settle(0.6)
                shot(app, "\(tag) 08 manhwa controls")
                closeReader(app)
            }
            goBack(app)
        }

        // Add manga sheet.
        let add = app.buttons["addManga"].firstMatch
        app.swipeDown()
        if add.waitForExistence(timeout: 3) {
            add.tap(); settle(1)
            shot(app, "\(tag) 09 add manga")
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.swipeDown(velocity: .fast) }
            settle(0.8)
        }

        for (index, name) in ["Browse", "Updates", "History", "Settings"].enumerated() {
            if openTab(name, in: app) {
                settle(1.5)
                shot(app, "\(tag) \(10 + index) \(name.lowercased())")
            }
        }
        // Settings sub-pages.
        for (index, row) in ["Reader", "Library", "Downloads"].enumerated() {
            let link = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
            if link.waitForExistence(timeout: 2) {
                link.tap(); settle(1)
                shot(app, "\(tag) \(14 + index) settings \(row.lowercased())")
                goBack(app)
            }
        }
        // The in-app browser and its toolbar.
        if openTab("Browse", in: app) {
            let site = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "MangaDex")).firstMatch
            if site.waitForExistence(timeout: 3) {
                site.tap(); settle(6)
                shot(app, "\(tag) 17 browser")
                let close = app.buttons["Close browser"].firstMatch
                if close.exists { close.tap() }
            }
        }
    }

    // MARK: Helpers

    private func settle(_ seconds: TimeInterval = 1.2) { Thread.sleep(forTimeInterval: seconds) }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(UIDevice.current.name) - \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor
    private func tapCenter(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    @MainActor
    private func closeReader(_ app: XCUIApplication) {
        let close = app.buttons["Close reader"].firstMatch
        if !close.exists { tapCenter(app); settle(0.5) }
        if close.waitForExistence(timeout: 2) { close.tap() }
        settle(0.8)
    }
    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        settle(0.8)
    }
    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) -> Bool {
        let tab = app.tabBars.buttons[name]
        if tab.exists { tab.tap(); return true }
        let button = app.buttons[name].firstMatch
        if button.exists { button.tap(); return true }
        return false
    }
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp(); settle(0.4)
        }
        return element.exists && element.isHittable
    }
}
