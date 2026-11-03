import XCTest

/// Captures the raw App Store screenshots. Skipped unless `SCREENSHOT_DIR` is set, which
/// `scripts/appstore-screenshots.sh` does through `TEST_RUNNER_SCREENSHOT_DIR`. Each shot is written
/// as `<number>-<name>.png`; `scripts/frame-screenshots.swift` adds the captions.
final class AppStoreScreenshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR to capture App Store screenshots")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func test01Reader() {
        let app = launch(opening: Fixture.note)
        shot(app, "01-reader")
    }

    @MainActor func test02Search() {
        let app = launch(opening: Fixture.note)
        app.buttons["Search"].tap()
        let field = app.textFields["Search this document"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Maybe")
        let count = app.staticTexts["Match Count"]
        XCTAssertTrue(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '1 of'"), object: count)], timeout: 120) == .completed)
        // Hide the keyboard so the highlighted page is visible.
        field.typeText("\n")
        sleep(1)
        shot(app, "02-search")
    }

    @MainActor func test03Titles() {
        let app = launch(opening: Fixture.titles)
        app.buttons["Pages and Titles"].tap()
        XCTAssertTrue(app.buttons["Titles"].waitForExistence(timeout: 10))
        app.buttons["Titles"].tap()
        XCTAssertTrue(app.collectionViews.buttons.firstMatch.waitForExistence(timeout: 60))
        sleep(1)
        shot(app, "03-titles")
    }

    @MainActor func test04Pages() {
        let app = launch(opening: Fixture.titles)
        app.buttons["Pages and Titles"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Page 1'")).firstMatch.waitForExistence(timeout: 10))
        sleep(3) // Page thumbnails render asynchronously.
        shot(app, "04-pages")
    }

    @MainActor func test05Library() {
        let app = XCUIApplication()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: the library slides over an open document.
            app.launchArguments = ["--ui-test-screenshots", "--ui-test-open", Fixture.path(Fixture.titles)]
            app.launch()
            waitUntilRendered(app)
            app.buttons["Library"].tap()
        } else {
            app.launchArguments = ["--ui-test-screenshots"]
            app.launch()
        }
        XCTAssertTrue(app.navigationBars["Sumi"].waitForExistence(timeout: 30))
        sleep(6) // Seeded renderings produce the row thumbnails.
        shot(app, "05-library")
    }

    @MainActor func test06AnnotatedPDF() {
        let app = launch(opening: Fixture.annotated)
        shot(app, "06-annotated-pdf")
    }

    // MARK: - Helpers

    @MainActor private func launch(opening name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-open", Fixture.path(name)]
        app.launch()
        waitUntilRendered(app)
        return app
    }

    /// Waits until the document is shown and the progress banner (with its Cancel button) is gone,
    /// so handwriting recognition has finished.
    @MainActor private func waitUntilRendered(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 60))
        _ = app.buttons["Cancel"].waitForNonExistence(timeout: 180)
        sleep(1)
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let url = directory.appendingPathComponent(name + ".png")
        XCTAssertNoThrow(try screenshot.pngRepresentation.write(to: url))
    }
}
