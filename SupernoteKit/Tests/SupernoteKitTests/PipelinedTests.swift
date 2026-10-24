import CoreGraphics
import Foundation
import XCTest
@testable import SupernoteKit

/// Pages are prepared concurrently and drawn in order (`PDFRenderer.pipelined`).
final class PipelinedTests: XCTestCase {
    /// Every index is prepared once and handed to `body` in order, on the calling thread.
    func testDeliversEveryIndexInOrderOnCallingThread() {
        for count in [0, 1, 3, 100] {
            for workers in [1, 2, 8] {
                let lock = NSLock()
                var prepared = [Int](repeating: 0, count: count)
                var delivered: [Int] = []
                PDFRenderer.pipelined(count, workers: workers, prepare: { index -> Int in
                    usleep(UInt32.random(in: 0...200))
                    lock.withLock { prepared[index] += 1 }
                    return index * 10
                }) { index, value in
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(value, index * 10)
                    delivered.append(index)
                }
                XCTAssertEqual(delivered, Array(0..<count), "count \(count), workers \(workers)")
                XCTAssertEqual(prepared, [Int](repeating: 1, count: count), "count \(count), workers \(workers)")
            }
        }
    }

    /// At most `workers` pages are being prepared or waiting to be drawn, which bounds memory,
    /// and with a slow drawer more than one is.
    func testPreparesAtMostWorkersAhead() {
        let lock = NSLock()
        var outstanding = 0, maxOutstanding = 0
        PDFRenderer.pipelined(100, workers: 4, prepare: { index -> Int in
            lock.withLock {
                outstanding += 1
                maxOutstanding = max(maxOutstanding, outstanding)
            }
            usleep(UInt32.random(in: 0...300))
            return index
        }) { _, _ in
            lock.withLock { outstanding -= 1 }
            usleep(1000)
        }
        XCTAssertEqual(outstanding, 0)
        XCTAssertLessThanOrEqual(maxOutstanding, 4)
        XCTAssertGreaterThan(maxOutstanding, 1)
    }

    /// An error from `body` ends the loop and is rethrown.
    func testRethrowsFromBody() {
        struct Stop: Error {}
        var delivered: [Int] = []
        XCTAssertThrowsError(try PDFRenderer.pipelined(50, workers: 4, prepare: { $0 }) { index, _ in
            delivered.append(index)
            if index == 5 { throw Stop() }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertEqual(delivered, Array(0...5))
    }

    // MARK: - Rendering

    /// Output page n shows page n's ink, for notes and for marks with pages left blank.
    func testEachOutputPageShowsItsOwnInk() throws {
        let notes = UpstreamFixtureTests.pageCounts.keys.filter { $0.hasSuffix(".note") }.sorted()
            .map(UpstreamFixtureTests.url) + [ExampleFileTests.examples.appendingPathComponent("Example Note.note")]
        for url in notes {
            let file = try SNFile(url: url)
            try assertPagesShowInk(of: file, in: PDFRenderer.renderNote(file), url.lastPathComponent)
        }
        let marks = [UpstreamFixtureTests.url("digest-n5-20230015-test.mark"),
                     ExampleFileTests.examples.appendingPathComponent("2026-03-22 Garmin Connect Integration.pdf.mark")]
        for url in marks {
            let file = try SNFile(url: url)
            let pdf = try PDFRenderer.renderMark(file, companion: nil, companionName: "missing.pdf")
            try assertPagesShowInk(of: file, in: pdf, url.lastPathComponent)
        }
    }

    /// Renders running at the same time, as in Quick Look and the apps, give identical pages.
    func testConcurrentRendersAgree() throws {
        let url = UpstreamFixtureTests.url("stroke-n5-20260016-isolation-tools-colors-widths.note")
        let lock = NSLock()
        var pdfs = [Data?](repeating: nil, count: 4)
        DispatchQueue.concurrentPerform(iterations: pdfs.count) { i in
            let pdf = try? PDFRenderer.render(contentsOf: url)
            lock.withLock { pdfs[i] = pdf }
        }
        let rendered = try pdfs.map { try pages(of: XCTUnwrap($0)) }
        XCTAssertEqual(rendered[0].count, 5)
        for other in rendered.dropFirst() { XCTAssertTrue(other == rendered[0], "concurrent renders differ") }
    }

    /// Compares each page of `pdf` with that page's ink drawn directly, at 1/4 scale. Mark pages
    /// without a mark page must be blank (apart from the missing-PDF notice on page 1).
    private func assertPagesShowInk(of file: SNFile, in pdf: Data, _ name: String) throws {
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!), name)
        let byNumber = Dictionary(file.pages.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        for n in 1...doc.numberOfPages {
            let page = file.fileType == .note ? file.pages[n - 1] : byNumber[n]
            let w = (page?.width ?? file.deviceWidth) / 4, h = (page?.height ?? file.deviceHeight) / 4
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            let expected = try bitmap(w, h) { ctx in
                if let page { PDFRenderer.drawInk(of: page, in: file, ctx: ctx, rect: rect, options: RenderOptions()) }
            }
            let actual = try bitmap(w, h) { ctx in
                let pdfPage = doc.page(at: n)!
                let box = pdfPage.getBoxRect(.mediaBox)
                ctx.scaleBy(x: CGFloat(w) / box.width, y: CGFloat(h) / box.height)
                ctx.drawPDFPage(pdfPage)
            }
            XCTAssertLessThan(Self.differing(actual, expected), Self.tolerance, "\(name) page \(n)")
        }
    }

    /// Share of pixels allowed to differ: rasterizing the PDF isn't pixel-identical to drawing
    /// directly (up to 0.15% with the missing-PDF notice); swapped fixture pages differ by 0.6% or more.
    static let tolerance = 0.003

    /// Share of pixels whose gray values differ by more than a quarter of the range.
    static func differing(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 64 }.count) / Double(a.count)
    }

    /// Every page of `pdf` at 72 dpi.
    private func pages(of pdf: Data) throws -> [[UInt8]] {
        let doc = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        return try (1...doc.numberOfPages).map { n in
            let page = doc.page(at: n)!
            let box = page.getBoxRect(.mediaBox)
            return try bitmap(Int(box.width), Int(box.height)) { $0.drawPDFPage(page) }
        }
    }

    /// Gray pixels, top row first, of `draw` on white.
    private func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) throws -> [UInt8] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(ctx)
        return try [UInt8](XCTUnwrap(ctx.makeImage()?.dataProvider?.data as Data?))
    }
}
