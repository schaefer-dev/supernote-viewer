import XCTest

/// iPad-only layout checks: library and reader columns, the reader inspector, rotation,
/// keyboard shortcuts and sheets. Screenshots are kept for visual review.
final class IPadLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func assertSingleLibraryControl(_ app: XCUIApplication) {
        let leadingButtons = app.navigationBars["Example Titles"].buttons.allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.midX < app.frame.midX
        }
        XCTAssertEqual(leadingButtons.count, 1, "Reader must have exactly one leading toolbar button, regardless of its label: \(leadingButtons.map(\.label))")
    }
    @MainActor func testIPadLayoutRotationKeyboardAndSheets() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = Fixture.launch(opening: Fixture.titles)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        sleep(1)
        let home = app.navigationBars["Supernote Viewer"]
        XCTAssertFalse(home.exists && home.isHittable, "Opening a document gives the page the whole screen")
        sleep(2)
        assertSingleLibraryControl(app)
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
        assertSingleLibraryControl(app)
        shot(app, "05 Portrait reader")

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["Search this document"].waitForExistence(timeout: 10), "Command-F opens the find bar")
        shot(app, "06 Find bar")
        app.buttons["Done"].firstMatch.tap()

        // Bring the library back with the reader's Library button.
        let showLibrary = app.buttons["Library"].firstMatch
        XCTAssertTrue(showLibrary.waitForExistence(timeout: 5), "The reader offers a way back to the library on iPad")
        XCTAssertEqual(app.buttons.matching(identifier: "Library").count, 1, "Only one library-reveal button is shown")
        XCTAssertFalse(app.buttons["Show Sidebar"].exists, "The automatic sidebar toggle must not duplicate Library")
        showLibrary.tap(); sleep(1)
        XCTAssertTrue(app.navigationBars["Supernote Viewer"].waitForExistence(timeout: 5), "The library is shown again")
        XCTAssertTrue(app.staticTexts["Recently Opened"].exists, "Home lists the document just opened")
        XCTAssertTrue(app.buttons["Sync All"].exists, "Sync All sits in the library toolbar")
        shot(app, "06b Library over reader")
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
