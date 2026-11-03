import CoreGraphics
import Foundation
import XCTest
@testable import SupernoteKit

final class MobileRenderingTests: XCTestCase {
    func testExplicitCompanionOutsideSourceDirectoryAndFileEquivalence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ExampleFileTests.examples.appendingPathComponent("2026-03-22 Garmin Connect Integration.pdf.mark")
        let companion = directory.appendingPathComponent("elsewhere.pdf")
        try FileManager.default.copyItem(at: source.deletingPathExtension(), to: companion)
        let data = try PDFRenderer.render(contentsOf: source, companionPDFURL: companion)
        let output = directory.appendingPathComponent("output.pdf")
        try PDFRenderer.write(contentsOf: source, companionPDFURL: companion, to: output)
        let a = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let b = try XCTUnwrap(PDFRenderer.openPDF(output))
        XCTAssertEqual(a.numberOfPages, b.numberOfPages)
        for index in 1...a.numberOfPages {
            XCTAssertEqual(try pixels(a.page(at: index)!), try pixels(b.page(at: index)!))
        }
        let missing = try PDFRenderer.render(contentsOf: source, companionPDFURL: nil)
        let absent = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: missing as CFData)!))
        XCTAssertNotEqual(try pixels(a.page(at: 1)!), try pixels(absent.page(at: 1)!))
    }
    func testCancellationRemovesFileAndDrainsWorkers() throws {
        let source = ExampleFileTests.examples.appendingPathComponent("Example Note.note")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let lock = NSLock()
        var cancelled = false
        XCTAssertThrowsError(try PDFRenderer.write(contentsOf: source, companionPDFURL: nil, to: output,
            options: RenderOptions(pageProgress: { _, _ in lock.withLock { cancelled = true } },
                                   maximumConcurrentPageWork: 2, isCancelled: { lock.withLock { cancelled } }))) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        var active = 0
        XCTAssertThrowsError(try PDFRenderer.pipelined(20, workers: 2, prepare: { index in
            lock.withLock { active += 1 }
            usleep(1000)
            lock.withLock { active -= 1 }
            return index
        }) { _, _ in throw CancellationError() })
        XCTAssertEqual(lock.withLock { active }, 0)
    }
    func testZeroWorkerCountCannotDeadlock() {
        var delivered: [Int] = []
        PDFRenderer.pipelined(3, workers: 0, prepare: { $0 }) { _, value in delivered.append(value) }
        XCTAssertEqual(delivered, [0, 1, 2])
    }
    func testFailedOCRDoesNotCacheEmptyRecognition() throws {
        let file = try SNFile(url: ExampleFileTests.examples.appendingPathComponent("Example Note.note"))
        let page = try XCTUnwrap(file.pages.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try TextLayer.cachedRecognition(page: page, file: file, cacheDirectory: directory,
                                                           recognizeImage: { _ in throw CancellationError() }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        var called = false
        let result = try TextLayer.cachedRecognition(page: page, file: file, cacheDirectory: directory, recognizeImage: { _ in called = true; return [] })
        XCTAssertTrue(called); XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }
    func testRecognitionCancellationSkipsAllPages() throws {
        let file = try SNFile(url: ExampleFileTests.examples.appendingPathComponent("Example Note.note"))
        XCTAssertTrue(TextLayer.recognize(file: file, cacheDirectory: nil, maximumConcurrentPageWork: 2, isCancelled: { true }).isEmpty)
    }
    private func pixels(_ page: CGPDFPage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 220, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let rect = CGRect(x: 0, y: 0, width: 160, height: 220)
        context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
    }
}
