import XCTest
import PDFKit
import SupernoteKit
@testable import SupernoteViewerIOS

@MainActor final class EngineIntegrationTests: XCTestCase {
    func testPublicMobileFixturesRenderWithBoundedFileOutput() async throws {
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("supernote-typescript")
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { ["note", "mark"].contains($0.pathExtension) }
        XCTAssertGreaterThanOrEqual(files.count, 13)
        let workspace = try Workspace()
        for url in files {
            let parsed = try SNFile(url: url)
            let output = workspace.url.appendingPathComponent(UUID().uuidString + ".pdf")
            try await EngineRenderer().render(.init(source: url, companion: nil, workspace: workspace), to: output,
                                              recognize: false, token: CancellationToken(), progress: { _, _ in })
            let pdf = try XCTUnwrap(PDFDocument(url: output), url.lastPathComponent)
            let expected = parsed.fileType == .note ? parsed.pages.count : max(1, parsed.pages.map(\.number).max() ?? 0)
            XCTAssertEqual(pdf.pageCount, expected, url.lastPathComponent)
        }
    }
    func testBundledAnnotatedPDFAndOriginalText() async throws {
        let mark = try XCTUnwrap(MobileLibrary.exampleURLs.first { $0.pathExtension == "mark" })
        let workspace = try Workspace()
        let output = workspace.url.appendingPathComponent("composed.pdf")
        let companion = mark.deletingPathExtension()
        try await EngineRenderer().render(.init(source: mark, companion: companion, workspace: workspace), to: output,
                                          recognize: false, token: CancellationToken(), progress: { _, _ in })
        let pdf = try XCTUnwrap(PDFDocument(url: output)), original = try XCTUnwrap(PDFDocument(url: companion))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, original.pageCount)
        XCTAssertFalse((pdf.string ?? "").isEmpty, "Original PDF text must be searchable before handwriting OCR")
    }
    func testOrdinaryPDFBypassesRenderingAndLocksAreRejected() async throws {
        let workspace = try Workspace()
        let url = workspace.url.appendingPathComponent("normal.pdf")
        let document = PDFDocument(); document.insert(PDFPage(image: UIImage(systemName: "doc")!)!, at: 0)
        XCTAssertTrue(document.write(to: url))
        let store = RecentDocumentsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let opener = DocumentOpenCoordinator(recents: store, renderer: RejectRenderer())
        let reference = DocumentReference(source: .imported, accountID: nil, fileID: "normal", name: "normal.pdf")
        opener.openLocal(reference, source: url)
        for _ in 0..<100 { if opener.displayed != nil || opener.error != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(opener.displayed); XCTAssertNil(opener.error); XCTAssertFalse(opener.recognizing)
        let locked = workspace.url.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "locked"]))
        opener.openLocal(.init(source: .imported, accountID: nil, fileID: "locked", name: "locked.pdf"), source: locked)
        for _ in 0..<100 { if opener.error != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(opener.displayed); XCTAssertNotNil(opener.error)
    }
}
private struct RejectRenderer: MobileRendering {
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping RenderProgress) async throws { throw ReaderError.message("Ordinary PDFs must bypass rendering") }
}
