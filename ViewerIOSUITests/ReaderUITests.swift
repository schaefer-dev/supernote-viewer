import XCTest

final class ReaderUITests: XCTestCase {
    @MainActor func testExampleOpensAndReaderToolsAppear() {
        let app = XCUIApplication()
        app.launchArguments = ["--start-in-examples"]
        app.launch()
        let example = app.buttons["Example Note.note"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        example.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["Example Note"].exists)
        let reader = XCTAttachment(screenshot: app.screenshot()); reader.name = "Reader"; reader.lifetime = .keepAlways; add(reader)
        app.buttons["Pages and Titles"].tap()
        XCTAssertTrue(app.buttons["Titles"].waitForExistence(timeout: 10))
        let pages = XCTAttachment(screenshot: app.screenshot()); pages.name = "Pages"; pages.lifetime = .keepAlways; add(pages)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        else { app.buttons["Pages and Titles"].tap() }
        app.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Maybe")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Maybe")).firstMatch.waitForExistence(timeout: 20))
    }
    /// The iPhone home screen (sidebar) lists recently opened documents directly.
    @MainActor func testHomeShowsRecentlyOpenedDocuments() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone home screen") }
        let app = XCUIApplication(); app.launchArguments = ["--start-in-examples"]; app.launch()
        let example = app.buttons["Example Note.note"]
        XCTAssertTrue(example.waitForExistence(timeout: 10)); example.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        for _ in 0..<3 where !app.staticTexts["Recently Opened"].exists {
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        XCTAssertTrue(app.staticTexts["Recently Opened"].waitForExistence(timeout: 5))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Home"; home.lifetime = .keepAlways; add(home)
        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example Note")).firstMatch
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30), "A recent document opens with one tap")
    }
    @MainActor func testAnnotatedExampleOpens() {
        let app = XCUIApplication(); app.launchArguments = ["--start-in-examples"]; app.launch()
        let example = app.buttons["2026-03-22 Garmin Connect Integration.pdf.mark"]
        XCTAssertTrue(example.waitForExistence(timeout: 10)); example.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Annotated PDF"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
