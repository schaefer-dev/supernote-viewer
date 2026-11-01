import XCTest

final class ReaderUITests: XCTestCase {
    @MainActor func testNoteOpensAndReaderToolsAppear() {
        let app = Fixture.launch(opening: Fixture.note)
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
    /// Back from a document opened on Home returns to Home, which lists it under Recently Opened.
    @MainActor func testBackReturnsHomeWithRecentlyOpenedDocuments() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone home screen") }
        let app = Fixture.launch(opening: Fixture.note)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Supernote Viewer"].waitForExistence(timeout: 5), "Back returns to Home")
        XCTAssertTrue(app.staticTexts["Recently Opened"].exists)
        XCTAssertTrue(app.buttons["Browse Dropbox"].exists)
        XCTAssertTrue(app.buttons["Sync All"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Home"; home.lifetime = .keepAlways; add(home)

        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example Note")).firstMatch
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30), "A recent document opens with one tap")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Supernote Viewer"].waitForExistence(timeout: 5), "Back from a recent returns to Home")

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Sync All When App Opens"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Settings"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["Done"].firstMatch.tap()

        app.buttons["Browse Dropbox"].tap()
        XCTAssertTrue(app.navigationBars["Browse Dropbox"].waitForExistence(timeout: 5))
        let dropbox = XCTAttachment(screenshot: app.screenshot()); dropbox.name = "Browse Dropbox"; dropbox.lifetime = .keepAlways; add(dropbox)
    }
    @MainActor func testAnnotatedPDFOpens() {
        let app = Fixture.launch(opening: Fixture.annotated)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Annotated PDF"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
