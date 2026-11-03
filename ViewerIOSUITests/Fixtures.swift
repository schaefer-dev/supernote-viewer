import XCTest

/// Repository sample files, opened by path through the debug-only `--ui-test-open` launch argument.
enum Fixture {
    static let note = "Example Note.note"
    static let titles = "Example Titles.note"
    static let annotated = "2026-03-22 Garmin Connect Integration.pdf.mark"
    static func path(_ name: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples").appendingPathComponent(name).path
    }
    @MainActor static func launch(opening name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-open", path(name)]
        app.launch()
        return app
    }
}
