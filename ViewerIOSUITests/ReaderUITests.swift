import XCTest

final class ReaderUITests: XCTestCase {
    @MainActor func testNoteOpensAndReaderToolsAppear() {
        let app = Fixture.launch(opening: Fixture.note)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.navigationBars["Example Note"].exists)
        XCTAssertEqual(app.staticTexts["Document Title"].label, "Example Note", "iPhone shows the full name below the bar")
        let reader = XCTAttachment(screenshot: app.screenshot()); reader.name = "Reader"; reader.lifetime = .keepAlways; add(reader)
        app.buttons["Pages and Titles"].tap()
        XCTAssertTrue(app.buttons["Titles"].waitForExistence(timeout: 10))
        let pages = XCTAttachment(screenshot: app.screenshot()); pages.name = "Pages"; pages.lifetime = .keepAlways; add(pages)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        else { app.buttons["Pages and Titles"].tap() }
        app.buttons["Search"].tap()
        let field = app.textFields["Search this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Maybe")
        let count = app.staticTexts["Match Count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(count, prefix: "1 of"), count.label)
    }
    @MainActor private func waitForLabel(_ element: XCUIElement, prefix: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }
    /// On iPhone the panels cover the page, so choosing a page or title closes them.
    @MainActor func testChoosingPageTitleOrResultClosesSheet() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone sheets") }
        let app = Fixture.launch(opening: Fixture.titles)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        let done = app.navigationBars["Pages and Titles"].buttons["Done"]

        app.buttons["Pages and Titles"].tap()
        let firstPage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 1")).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 10), "The Pages tab shows a grid of pages")
        sleep(2)
        let grid = XCTAttachment(screenshot: app.screenshot()); grid.name = "Page grid"; grid.lifetime = .keepAlways; add(grid)
        let secondPage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Page 2")).firstMatch
        (secondPage.exists ? secondPage : firstPage).tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Choosing a page closes the sheet")

        app.buttons["Pages and Titles"].tap()
        app.buttons["Titles"].tap()
        let title = app.collectionViews.buttons.firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "The titles fixture lists titles")
        title.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Choosing a title closes the sheet")

    }
    /// Find works like a browser's: type, read "x of y matches", step with the arrows and wrap around.
    @MainActor func testFindBarStepsThroughMatches() {
        let app = Fixture.launch(opening: Fixture.titles)
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
        app.buttons["Search"].tap()
        let field = app.textFields["Search this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Search opens a find bar over the page")
        let opened = XCTAttachment(screenshot: app.screenshot()); opened.name = "Find bar opened"; opened.lifetime = .keepAlways; add(opened)
        XCTAssertTrue(app.buttons["Pages and Titles"].exists, "The reader toolbar stays in place behind the find bar")
        field.typeText("e")
        let count = app.staticTexts["Match Count"]
        XCTAssertTrue(waitForLabel(count, prefix: "1 of", timeout: 60), "Typing selects the first match: \(count.label)")
        sleep(2)
        let total = count.label.components(separatedBy: " ")[2]
        XCTAssertGreaterThan(Int(total) ?? 0, 1, "The fixture has several matches: \(count.label)")
        let bar = XCTAttachment(screenshot: app.screenshot()); bar.name = "Find bar"; bar.lifetime = .keepAlways; add(bar)
        app.buttons["Next Match"].tap()
        XCTAssertTrue(waitForLabel(count, prefix: "2 of"), count.label)
        app.buttons["Next Match"].tap(); app.buttons["Next Match"].tap()
        XCTAssertTrue(waitForLabel(count, prefix: "4 of"), count.label)
        let fourth = XCTAttachment(screenshot: app.screenshot()); fourth.name = "Find bar fourth match"; fourth.lifetime = .keepAlways; add(fourth)
        app.buttons["Previous Match"].tap(); app.buttons["Previous Match"].tap()
        XCTAssertTrue(waitForLabel(count, prefix: "2 of"), count.label)
        app.buttons["Previous Match"].tap()
        XCTAssertTrue(waitForLabel(count, prefix: "1 of"), count.label)
        app.buttons["Previous Match"].tap()
        XCTAssertTrue(waitForLabel(count, prefix: "\(total) of"), "Previous from the first match wraps to the last: \(count.label)")
        field.typeText("\n")
        XCTAssertTrue(waitForLabel(count, prefix: "1 of"), "Return goes to the next match and wraps: \(count.label)")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Done closes the find bar")
        app.buttons["Search"].tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["Match Count"], prefix: "1 of"), "Reopening keeps the term")
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

final class FavoritesUITests: XCTestCase {
    /// A page favorite opens at its page, also when another document was open before.
    @MainActor func testPageFavoritesOpenAtTheirPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-favorites", "--ui-test-page-favorites", "--ui-test-open", Fixture.path("2026-03-22 Garmin Connect Integration.pdf")]
        app.launch()
        for (row, page) in [("Document 1 · Page 3", 3), ("Document 2 · Page 2", 2), ("Document 1 · Page 3", 3)] {
            let favorite = app.staticTexts[row]
            XCTAssertTrue(favorite.waitForExistence(timeout: 10), row)
            favorite.tap()
            XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 30))
            // The star is filled only on the bookmarked page.
            XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 5), "\(row) opens at page \(page)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor func testHomeFavoritesAndReaderToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-favorites", "--ui-test-open", Fixture.path(Fixture.note)]
        app.launch()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Document 1"].exists)
        app.buttons["Show All"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Document 6"].exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
        app.staticTexts["Document 1"].tap()
        // The reader's star bookmarks the page on screen, separately from the document favorite.
        let star = app.buttons["Add to Favorites"]
        XCTAssertTrue(star.waitForExistence(timeout: 30))
        star.tap()
        let remove = app.buttons["Remove from Favorites"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        if app.navigationBars.buttons["Favorites"].exists { app.navigationBars.buttons["Favorites"].tap() }
        else if app.buttons["Library"].exists { app.buttons["Library"].tap() }
        let bookmark = app.staticTexts["Document 1 · Page 1"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5), "The bookmark is listed with its document and page")
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Favorites with bookmark"; list.lifetime = .keepAlways; add(list)
    }
}
