import XCTest
@testable import SupernoteViewerIOS

final class ReviewPromptTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "review-prompt-tests")!
        defaults.removePersistentDomain(forName: "review-prompt-tests")
    }

    func testAsksOncePerVersionAfterEnoughDocuments() {
        let prompt = ReviewPrompt(defaults: defaults, version: "2.0.0", enabled: true)
        for _ in 1..<ReviewPrompt.documentsBeforeAsking {
            prompt.documentOpened()
            XCTAssertFalse(prompt.shouldAskOnReturningToLibrary(), "too early")
        }
        prompt.documentOpened()
        XCTAssertTrue(prompt.shouldAskOnReturningToLibrary())
        prompt.documentOpened()
        XCTAssertFalse(prompt.shouldAskOnReturningToLibrary(), "only once per version")
        XCTAssertTrue(ReviewPrompt(defaults: defaults, version: "2.1.0", enabled: true).shouldAskOnReturningToLibrary(),
                      "a new version may ask again")
    }

    func testNeverAsksWhenDisabled() {
        let prompt = ReviewPrompt(defaults: defaults, version: "2.0.0", enabled: false)
        for _ in 0..<10 { prompt.documentOpened() }
        XCTAssertFalse(prompt.shouldAskOnReturningToLibrary())
    }

    func testDebugBuildsDoNotAskWithoutOptIn() {
        XCTAssertFalse(ReviewPrompt.enabledInThisBuild, "unit and UI test runs must never show the prompt")
    }
}
