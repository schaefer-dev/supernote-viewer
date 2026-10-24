import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SupernoteKit
import UniformTypeIdentifiers

// Usage: snrender <file.note|file.pdf.mark> <out.pdf> [--png <dir>] [--dpi <n>] [--bitmap] [--ocr] [--benchmark [n]]
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: snrender <input> <out.pdf> [--png <dir>] [--dpi <n>] [--bitmap] [--ocr] [--benchmark [n]]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let pngDir = args.firstIndex(of: "--png").map { URL(fileURLWithPath: args[$0 + 1]) }
let dpi = args.firstIndex(of: "--dpi").flatMap { Double(args[$0 + 1]) } ?? 100
var options = RenderOptions(vector: !args.contains("--bitmap"), textLayer: args.contains("--ocr"))
// --benchmark [n]: after a warm-up render, renders n more times (default 5) and reports timings.
let benchmarkRuns = args.firstIndex(of: "--benchmark").map { i in
    i + 1 < args.count ? Int(args[i + 1]) ?? 5 : 5
}

func elapsed(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

func stats(_ samples: [Double]) -> String {
    let sorted = samples.sorted()
    let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
        : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    let mean = sorted.reduce(0, +) / Double(sorted.count)
    return String(format: "min %7.1fms  median %7.1fms  mean %7.1fms  max %7.1fms",
                  sorted.first! * 1000, median * 1000, mean * 1000, sorted.last! * 1000)
}

/// Renders `runs` times after a warm-up and prints total and average per-page timings.
/// Page times are the gaps between page-progress callbacks, so page 1 includes setup and recognition.
func benchmark(runs: Int) throws {
    var totalTimes: [Double] = [], pageTimes: [[Double]] = []
    for run in 0...runs {
        var pages: [Double] = []
        var last = DispatchTime.now().uptimeNanoseconds
        options.pageProgress = { _, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            pages.append(Double(now - last) / 1e9)
            last = now
        }
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try PDFRenderer.render(contentsOf: input, options: options)
        let total = elapsed(since: start)
        options.pageProgress = nil
        guard run > 0 else { continue }  // warm-up

        totalTimes.append(total)
        pageTimes.append(pages)
    }

    print("benchmark: \(runs) run(s) after warm-up, \(options.vector ? "vector" : "bitmap")\(options.textLayer ? " +ocr" : "")")
    print("  total    \(stats(totalTimes))")
    let pageCount = pageTimes.first?.count ?? 0
    if pageCount > 0 {
        print("  per page \(stats(pageTimes.map { $0.reduce(0, +) / Double(pageCount) }))  (\(pageCount) pages)")
    }
}

do {
    let file = try SNFile(url: input)
    print("\(file.fileType) \(file.signature) \(file.header["APPLY_EQUIPMENT"] ?? "?") \(file.deviceWidth)x\(file.deviceHeight), \(file.pages.count) page(s)")
    for page in file.pages {
        let layers = page.visibleLayers(fileType: file.fileType).map(\.name).joined(separator: ",")
        let strokes = page.strokes(in: file)
        let strokeInfo = strokes.map { s in
            "strokes=\(s.count) ink=\(s.filter(\.isInk).count) deleted=\(s.filter(\.isDeleted).count) erasers=\(s.filter(\.isEraser).count)"
        } ?? "strokes=none"
        print("  page \(page.number): \(page.width)x\(page.height) style=\(page.style) visible=[\(layers)] \(strokeInfo)")
    }

    if let benchmarkRuns { try benchmark(runs: max(benchmarkRuns, 1)) }

    let start = Date()
    let pdf = try PDFRenderer.render(contentsOf: input, options: options)
    try pdf.write(to: output)
    print(String(format: "wrote %@ (%d KB) in %.2fs", output.path, pdf.count / 1024, Date().timeIntervalSince(start)))

    if options.textLayer, let doc = PDFDocument(data: pdf) {
        for i in 0..<doc.pageCount {
            let text = (doc.page(at: i)?.string ?? "").split(whereSeparator: \.isNewline).joined(separator: " / ")
            print("  text p\(i + 1): \(text)")
        }
        func printOutline(_ item: PDFOutline, depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                let page = child.destination?.page.map { doc.index(for: $0) + 1 }.map(String.init) ?? "?"
                print("  toc \(String(repeating: "  ", count: depth))\(child.label ?? "") (p\(page))")
                printOutline(child, depth: depth + 1)
            }
        }
        if let root = doc.outlineRoot { printOutline(root, depth: 0) }
    }

    if let pngDir {
        try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
        let doc = CGPDFDocument(output as CFURL)!
        for i in 1...doc.numberOfPages {
            let page = doc.page(at: i)!
            let box = page.getBoxRect(.mediaBox)
            let scale = dpi / 72
            let w = Int(box.width * scale), h = Int(box.height * scale)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            let url = pngDir.appendingPathComponent(String(format: "page-%02d.png", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            print("  \(url.path)")
        }
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
