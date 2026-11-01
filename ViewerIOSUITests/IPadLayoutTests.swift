import XCTest

/// iPad-only layout checks: three-column navigation, the reader inspector, rotation,
/// keyboard shortcuts and sheets. Screenshots are kept for visual review.
final class IPadLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testIPadLayoutRotationKeyboardAndSheets() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launchArguments = ["--start-in-examples"]; app.launch()

        let example = app.buttons["Example Titles.note"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        shot(app, "01 Landscape library")
        example.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        sleep(1)
        XCTAssertFalse(app.buttons["Example Titles.note"].isHittable, "Opening a document gives the page the whole screen")
        sleep(2)
        shot(app, "02 Landscape reader")

        app.buttons["Pages and Titles"].tap()
        XCTAssertTrue(app.buttons["Titles"].waitForExistence(timeout: 10), "Regular width shows pages in an inspector")
        app.buttons["Titles"].tap()
        sleep(1)
        shot(app, "03 Inspector titles")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(app.buttons["Search"].exists, "The reader survives rotation")
        shot(app, "04 Portrait reader with inspector")
        app.buttons["Pages and Titles"].tap()
        sleep(1)
        shot(app, "05 Portrait reader")

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Command-F opens search")
        shot(app, "06 Search sheet")
        app.buttons["Done"].firstMatch.tap()

        // Bring the library back with the reader's Library button.
        let showLibrary = app.buttons["Library"].firstMatch
        XCTAssertTrue(showLibrary.waitForExistence(timeout: 5), "The reader offers a way back to the library on iPad")
        showLibrary.tap(); sleep(1)
        XCTAssertTrue(app.buttons["Example Titles.note"].isHittable, "The library is shown again")
        shot(app, "06b Library over reader")
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Settings and Import are one menu away whenever the library is visible")
        more.tap()
        let settings = app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
            shot(app, "07 Settings sheet")
            app.buttons["Done"].firstMatch.tap()
        } else {
            shot(app, "07 Settings button missing")
            XCTFail("Settings must be reachable on iPad")
        }
        // XCUITest taps are unreliable after rotating back to landscape, so only verify state there.
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertTrue(app.buttons["Search"].exists, "The reader survives rotating back to landscape")
        shot(app, "08 Landscape after rotation")
    }
}
