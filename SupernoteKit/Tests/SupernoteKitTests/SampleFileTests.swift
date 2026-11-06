import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import SupernoteKit

/// The showcase documents in `samples/`, bundled in the iOS app and used for the App Store
/// screenshots. These checks keep them renderable as the renderer changes.
final class SampleFileTests: XCTestCase {
    static let samples = SupernoteKitTests.repo.appendingPathComponent("samples")
    let notebookURL = samples.appendingPathComponent("Handwritten Notes.note")
    let markURL = samples.appendingPathComponent("Meditations, Book II.pdf.mark")

    func testVectorStrokesReproduceEveryBitmapLayer() throws {
        for url in [notebookURL, markURL] {
            try assertVectorStrokesReproduceBitmaps(url)
        }
    }

    /// The notebook carries handwritten titles, which the reader shows as a table of contents.
    func testNotebookHasTitlesAndRenders() throws {
        let file = try SNFile(url: notebookURL)
        XCTAssertFalse(file.titles.isEmpty)
        let pdf = try XCTUnwrap(PDFDocument(data: PDFRenderer.render(contentsOf: notebookURL)))
        XCTAssertEqual(pdf.pageCount, file.pages.count)
    }

    /// The annotations render on top of every page of the bundled original PDF.
    func testAnnotatedPDFRendersOnItsOriginal() throws {
        let companion = SNFile.companionPDFURL(forMark: markURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path), "The original PDF must sit next to the .mark file")
        let original = try XCTUnwrap(PDFDocument(url: companion))
        let rendered = try XCTUnwrap(PDFDocument(data: PDFRenderer.render(contentsOf: markURL)))
        XCTAssertEqual(rendered.pageCount, original.pageCount)
        XCTAssertTrue(rendered.page(at: 0)?.string?.contains("Meditations") == true, "The original's text stays searchable")
    }
}
