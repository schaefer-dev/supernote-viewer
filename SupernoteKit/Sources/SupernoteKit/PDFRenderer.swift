import CoreGraphics
import CoreText
import Foundation

/// Options for PDF rendering.
public struct RenderOptions {
    /// Draw handwriting as vector outlines from the stroke data (falls back to bitmaps per layer).
    public var vector: Bool
    /// Add an invisible text layer with recognized handwriting.
    public var textLayer: Bool
    /// Where recognized text is cached between renders.
    public var ocrCacheDirectory: URL?
    /// Called with handwriting recognition progress (pages done, total), from any thread.
    public var progress: ((_ done: Int, _ total: Int) -> Void)?
    /// Called after each output page is drawn (pages done, total), from the rendering thread.
    /// Drawing follows recognition.
    public var pageProgress: ((_ done: Int, _ total: Int) -> Void)?

    /// Upper bound for page preparation and recognition work. Values below one use one worker.
    public var maximumConcurrentPageWork: Int
    /// Cooperative cancellation; called from multiple threads. Keep this callback thread safe.
    public var isCancelled: () -> Bool
    /// Failed page recognition, called from a worker thread. Failed pages are not cached.
    public var recognitionError: ((Int, Error) -> Void)?

    public init(vector: Bool = true, textLayer: Bool = false, ocrCacheDirectory: URL? = nil,
                progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                pageProgress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                maximumConcurrentPageWork: Int = 4,
                isCancelled: @escaping () -> Bool = { false },
                recognitionError: ((Int, Error) -> Void)? = nil) {
        self.maximumConcurrentPageWork = max(1, maximumConcurrentPageWork)
        self.isCancelled = isCancelled
        self.recognitionError = recognitionError
        self.vector = vector
        self.textLayer = textLayer
        self.ocrCacheDirectory = ocrCacheDirectory
        self.progress = progress
        self.pageProgress = pageProgress
    }
}

/// Renders Supernote files to PDF data.
public enum PDFRenderer {
    /// Bumped when output changes, so cached renders are redone.
    public static let version = 7

    /// Renders a `.note` or `.mark` file. For `.mark`, the companion PDF next to it is used when readable.
    public static func render(contentsOf url: URL, options: RenderOptions = RenderOptions()) throws -> Data {
        let file = try SNFile(url: url)
        switch file.fileType {
        case .note:
            return try renderNote(file, options: options)
        case .mark:
            let companion = SNFile.companionPDFURL(forMark: url)
            return try renderMark(file, companion: openPDF(companion), companionName: companion.lastPathComponent,
                                  options: options)
        }
    }

    /// In this overload nil deliberately means no companion, without sibling discovery.
    public static func render(contentsOf url: URL, companionPDFURL: URL?,
                              options: RenderOptions = RenderOptions()) throws -> Data {
        let file = try SNFile(url: url)
        return try makePDF { try draw(file, companionPDFURL: companionPDFURL, in: $0, options: options) }
    }

    /// Writes directly to a file; incomplete output is removed on any failure.
    public static func write(contentsOf url: URL, companionPDFURL: URL?, to output: URL,
                             options: RenderOptions = RenderOptions()) throws {
        let file = try SNFile(url: url)
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw SNError.malformed("could not create output PDF; check available storage")
        }
        do {
            defer { ctx.closePDF() }
            try draw(file, companionPDFURL: companionPDFURL, in: ctx, options: options)
            try checkCancellation(options)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func draw(_ file: SNFile, companionPDFURL: URL?, in ctx: CGContext,
                             options: RenderOptions) throws {
        try checkCancellation(options)
        if file.fileType == .note { try drawNote(file, in: ctx, options: options) }
        else {
            let companion = companionPDFURL.flatMap(openPDF)
            if companionPDFURL != nil && companion == nil {
                throw SNError.malformed("Original PDF is unreadable or password locked. Import an unlocked PDF.")
            }
            try drawMark(file, companion: companion,
                         companionName: companionPDFURL?.lastPathComponent ?? "original PDF", in: ctx, options: options)
        }
        try checkCancellation(options)
    }

    public static func renderNote(_ file: SNFile, options: RenderOptions = RenderOptions()) throws -> Data {
        try makePDF { try drawNote(file, in: $0, options: options) }
    }

    private static func drawNote(_ file: SNFile, in ctx: CGContext, options: RenderOptions) throws {
        try checkCancellation(options)
        let words = recognizeIfNeeded(file, options)
        var outlinePages: [Int: OutlinePage] = [:]

        try pipelined(
            file.pages.count, workers: options.maximumConcurrentPageWork, isCancelled: options.isCancelled,
            prepare: { prepareInk(of: file.pages[$0], in: file, options: options) })
        { index, ink in
            try checkCancellation(options)
            let page = file.pages[index]
            let rect = CGRect(origin: .zero, size: pointSize(page.width, page.height))
            beginPage(ctx, rect)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(rect)
            drawInk(ink, of: page, in: file, ctx: ctx, rect: rect)
            let pageWords = textWords(of: page, in: file, recognized: words[page.number])
            TextLayer.draw(pageWords, in: ctx, rect: rect)
            ctx.endPDFPage()
            outlinePages[page.number] = OutlinePage(index: index + 1, width: page.width, height: page.height,
                                                    words: pageWords)
            options.pageProgress?(index + 1, file.pages.count)
        }
        try checkCancellation(options)
        if options.textLayer { setOutline(outline(titles: file.titles, pages: outlinePages), in: ctx) }
    }

    public static func renderMark(_ file: SNFile, companion: CGPDFDocument?, companionName: String,
                                  options: RenderOptions = RenderOptions()) throws -> Data {
        try makePDF { try drawMark(file, companion: companion, companionName: companionName, in: $0, options: options) }
    }

    private static func drawMark(_ file: SNFile, companion: CGPDFDocument?, companionName: String,
                                 in ctx: CGContext, options: RenderOptions) throws {
        let marksByNumber = Dictionary(file.pages.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        let highlights = MarkHighlight.load(from: file)
        try checkCancellation(options)
        let words = recognizeIfNeeded(file, options)
        let pdfCount = companion?.numberOfPages ?? 0
        let pageCount = max(pdfCount, file.pages.map(\.number).max() ?? 0)

        var outlinePages: [Int: OutlinePage] = [:]
        let outputCount = max(pageCount, 1)
        try pipelined(
            outputCount, workers: options.maximumConcurrentPageWork, isCancelled: options.isCancelled,
            prepare: { index in marksByNumber[index + 1].map { prepareInk(of: $0, in: file, options: options) }
        }) { index, ink in
            try checkCancellation(options)
            let number = index + 1
            let mark = marksByNumber[number]
            let deviceW = mark?.width ?? file.deviceWidth
            let deviceH = mark?.height ?? file.deviceHeight
            let pdfPage = number <= pdfCount ? companion?.page(at: number) : nil

            // Output page: the PDF page expanded to the device aspect ratio (or the device size).
            let box: CGRect
            var pageRect = CGRect.zero
            if let pdfPage {
                let size = displayedSize(pdfPage)
                let aspect = Double(deviceW) / Double(deviceH)
                if size.width / size.height > aspect {
                    box = CGRect(x: 0, y: 0, width: size.width, height: size.width / aspect)
                } else {
                    box = CGRect(x: 0, y: 0, width: size.height * aspect, height: size.height)
                }
                pageRect = CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                                  width: size.width, height: size.height)
            } else {
                box = CGRect(origin: .zero, size: pointSize(deviceW, deviceH))
            }

            beginPage(ctx, box)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(box)

            if let pdfPage {
                ctx.saveGState()
                ctx.clip(to: pageRect)
                ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(pdfPage)
                ctx.restoreGState()
                for h in highlights[number - 1] ?? [] { h.draw(in: ctx, pageRect: pageRect) }
            }

            if let mark, let ink {
                drawInk(ink, of: mark, in: file, ctx: ctx, rect: box)
                let markWords = textWords(of: mark, in: file, recognized: words[mark.number])
                TextLayer.draw(markWords, in: ctx, rect: box)
                outlinePages[number] = OutlinePage(index: number, width: mark.width, height: mark.height,
                                                   words: markWords)
            }

            if companion == nil && number == 1 {
                drawNotice("Original PDF not found or not readable: \(companionName)", in: ctx, box: box)
            }
            ctx.endPDFPage()
            options.pageProgress?(number, outputCount)
        }
        try checkCancellation(options)
        if options.textLayer { setOutline(outline(titles: file.titles, pages: outlinePages), in: ctx) }
    }

    private static func checkCancellation(_ options: RenderOptions) throws {
        if options.isCancelled() { throw CancellationError() }
    }

    /// One visible layer of a page, ready to draw.
    enum PreparedLayer {
        /// Stroke outlines, over typed text box images (in page pixels).
        case vector([SNStroke], textBoxes: [(image: CGImage, rect: CGRect)])
        /// The layer's bitmap, covering the page.
        case image(CGImage)
    }

    /// Draws a page's visible layers bottom-up into `rect`. Each handwriting layer is drawn as
    /// vector outlines when the stroke data reproduces its bitmap, otherwise as the bitmap.
    /// Typed text boxes are drawn from the bitmap, since TOTALPATH only has their frames.
    /// The template background is always a bitmap. Layers whose bitmap can't be decoded are drawn
    /// from their strokes if they have any, and left out otherwise.
    static func drawInk(of page: SNPage, in file: SNFile, ctx: CGContext, rect: CGRect, options: RenderOptions) {
        drawInk(prepareInk(of: page, in: file, options: options), of: page, in: file, ctx: ctx, rect: rect)
    }

    /// Decodes a page's visible layers for `drawInk(_:of:in:ctx:rect:)`, choosing vector or bitmap
    /// per layer. Doesn't touch a context, so pages can be prepared concurrently.
    static func prepareInk(of page: SNPage, in file: SNFile, options: RenderOptions) -> [PreparedLayer] {
        let strokes = options.vector ? page.strokes(in: file) : nil

        func vector(_ layerStrokes: [SNStroke], textBoxes: [CGRect], codes: [UInt8]?) -> PreparedLayer {
            let images = textBoxes.compactMap { textRect in
                codes.flatMap { LayerCompositor.textBoxImage(codes: $0, rect: textRect, page: page, file: file) }
            }
            return .vector(layerStrokes, textBoxes: images.map { (image: $0.0, rect: $0.1) })
        }

        var prepared: [PreparedLayer] = []
        for layer in page.visibleLayers(fileType: file.fileType) {
            let content = LayerCompositor.content(of: layer, page: page, in: file)
            if let strokes, let index = SNStroke.layerIndex(forLayerName: layer.name) {
                let layerStrokes = strokes.filter { $0.layer == index }
                switch content {
                case .codes(let codes)?:
                    let textRects = layerStrokes.filter { !$0.isDeleted }.compactMap(\.textBox?.rect)
                    if VectorRenderer.covers(layerStrokes, codes: codes, width: page.width, height: page.height,
                                             ignoring: textRects) {
                        prepared.append(vector(layerStrokes, textBoxes: textRects, codes: codes))
                        continue
                    }
                case nil where layerStrokes.contains(where: \.isInk):
                    // The bitmap is unusable; the strokes are the best remaining source.
                    prepared.append(vector(layerStrokes, textBoxes: [], codes: nil))
                    continue
                default:
                    break
                }
            }
            if content != nil, let image = LayerCompositor.render(page: page, in: file, background: .transparent,
                                                                  include: { $0.name == layer.name }) {
                prepared.append(.image(image))
            }
        }
        return prepared
    }

    /// Draws layers from `prepareInk` into `rect`.
    static func drawInk(_ layers: [PreparedLayer], of page: SNPage, in file: SNFile, ctx: CGContext, rect: CGRect) {
        for layer in layers {
            switch layer {
            case .vector(let strokes, let textBoxes):
                ctx.saveGState()
                // Page pixels (origin top-left, y down) -> rect.
                ctx.concatenate(CGAffineTransform(a: rect.width / CGFloat(page.width), b: 0, c: 0,
                                                  d: -rect.height / CGFloat(page.height),
                                                  tx: rect.minX, ty: rect.maxY))
                ctx.interpolationQuality = .high
                for (image, r) in textBoxes {
                    // Undo the y flip locally so the image is drawn upright.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: r.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
                    ctx.restoreGState()
                }
                VectorRenderer.draw(strokes, in: ctx, file: file)
                ctx.restoreGState()
            case .image(let image):
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
            }
        }
    }

    /// Calls `prepare` for indices `0..<count` on background threads and `body` with each result in
    /// index order on the calling thread. At most `workers` results are being prepared or waiting
    /// for `body`, which bounds memory: a prepared page holds its decoded layer bitmaps. More than
    /// 4 workers don't render faster, since drawing into the PDF on the calling thread is the
    /// bottleneck, but each one adds a page of bitmaps.
    static func pipelined<T>(_ count: Int, workers prepareWorkerCount: Int = 4,
                             isCancelled: @escaping () -> Bool = { false },
                             prepare: @escaping (Int) -> T, _ body: (Int, T) throws -> Void) rethrows {
        let workerCount = max(1, prepareWorkerCount)
        let group = DispatchGroup()
        let lock = NSLock()
        var stopped = false
        defer {
            lock.withLock { stopped = true }
            group.wait()
        }
        var results = [T?](repeating: nil, count: count)
        let ready = (0..<count).map { _ in DispatchSemaphore(value: 0) }
        func enqueuePrepare(_ index: Int) {
            guard index < count, !isCancelled(), !lock.withLock({ stopped }) else { return }
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave(); ready[index].signal() }
                guard !isCancelled(), !lock.withLock({ stopped }) else { return }
                let value = autoreleasepool { prepare(index) }
                lock.withLock { results[index] = value }
            }
        }
        for index in 0..<min(workerCount, count) { enqueuePrepare(index) }
        for index in 0..<count {
            if isCancelled() { break }
            ready[index].wait()
            if isCancelled() { break }
            let value = lock.withLock { results[index].take()! }
            try body(index, value)
            enqueuePrepare(index + workerCount)
        }
    }

    /// Words for the invisible text layer: typed text boxes verbatim, plus recognized handwriting
    /// outside them (OCR would only add a second, possibly garbled copy of the typed text).
    static func textWords(of page: SNPage, in file: SNFile, recognized: [RecognizedWord]?) -> [RecognizedWord] {
        let w = CGFloat(page.width), h = CGFloat(page.height)
        let typed = page.textBoxes(in: file).map { box in
            RecognizedWord(text: box.text, box: CGRect(x: box.rect.minX / w, y: 1 - box.rect.maxY / h,
                                                       width: box.rect.width / w, height: box.rect.height / h))
        }
        let handwritten = (recognized ?? []).filter { word in
            !typed.contains { $0.box.contains(CGPoint(x: word.box.midX, y: word.box.midY)) }
        }
        return typed + handwritten
    }

    // MARK: - Outline

    /// An output page as the outline sees it.
    struct OutlinePage {
        /// 1-based page number in the output PDF.
        var index: Int
        /// Device page size in pixels, which title rects refer to.
        var width: Int
        var height: Int
        /// Text layer words, in the coordinates of `RecognizedWord`.
        var words: [RecognizedWord]
    }

    /// The PDF outline (Preview's Table of Contents) for `titles`, each labeled with the text
    /// layer words inside it, nested by title level. `pages` is keyed by `SNPage.number`; titles
    /// on other pages are left out. Nil when no entry remains.
    static func outline(titles: [SNTitle], pages: [Int: OutlinePage]) -> [String: Any]? {
        final class Entry {
            let level: Int
            let dictionary: [String: Any]
            var children: [Entry] = []
            init(level: Int, dictionary: [String: Any]) { self.level = level; self.dictionary = dictionary }

            var outline: [String: Any] {
                var d = dictionary
                if !children.isEmpty { d[kCGPDFOutlineChildren as String] = children.map(\.outline) }
                return d
            }
        }

        let root = Entry(level: 0, dictionary: [:])
        var open = [root]  // the current entry at each nesting depth
        for title in titles {
            guard let page = pages[title.pageNumber] else { continue }
            let entry = Entry(level: title.level, dictionary: [
                kCGPDFOutlineTitle as String: outlineLabel(for: title, on: page),
                kCGPDFOutlineDestination as String: page.index,
            ])
            while open.count > 1, open[open.count - 1].level >= title.level { open.removeLast() }
            open[open.count - 1].children.append(entry)
            open.append(entry)
        }
        return root.children.isEmpty ? nil : root.outline
    }

    /// Text layer words whose center is inside the title, or "Page n" when there are none.
    static func outlineLabel(for title: SNTitle, on page: OutlinePage) -> String {
        let w = CGFloat(page.width), h = CGFloat(page.height)
        // Page pixels (origin top-left) -> word coordinates (normalized, origin bottom-left).
        let box = CGRect(x: title.rect.minX / w, y: 1 - title.rect.maxY / h,
                         width: title.rect.width / w, height: title.rect.height / h)
        let text = page.words.filter { box.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            .map(\.text).joined(separator: " ")
        return text.isEmpty ? "Page \(page.index)" : text
    }

    private static func setOutline(_ outline: [String: Any]?, in ctx: CGContext) {
        guard let outline else { return }
        CGPDFContextSetOutline(ctx, outline as CFDictionary)
    }

    private static func recognizeIfNeeded(_ file: SNFile, _ options: RenderOptions) -> [Int: [RecognizedWord]] {
        guard options.textLayer else { return [:] }
        return TextLayer.recognize(file: file, cacheDirectory: options.ocrCacheDirectory, progress: options.progress,
                                   maximumConcurrentPageWork: options.maximumConcurrentPageWork,
                                   isCancelled: options.isCancelled, recognitionError: options.recognitionError)
    }

    public static func openPDF(_ url: URL) -> CGPDFDocument? {
        guard let doc = CGPDFDocument(url as CFURL) else { return nil }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { return nil }
        return doc
    }

    // MARK: - Helpers

    static func pointSize(_ w: Int, _ h: Int) -> CGSize {
        CGSize(width: Double(w) / SNFile.dpi * 72, height: Double(h) / SNFile.dpi * 72)
    }

    /// Crop box size after applying the page's /Rotate.
    static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let r = page.getBoxRect(.cropBox)
        let angle = ((page.rotationAngle % 360) + 360) % 360
        return angle == 90 || angle == 270 ? CGSize(width: r.height, height: r.width) : r.size
    }

    private static func makePDF(_ body: (CGContext) throws -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw SNError.malformed("could not create PDF context")
        }
        do { try body(ctx) }
        catch { ctx.closePDF(); throw error }
        ctx.closePDF()
        return data as Data
    }

    private static func beginPage(_ ctx: CGContext, _ rect: CGRect) {
        var r = rect
        let boxData = Data(bytes: &r, count: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
    }

    private static func drawNotice(_ text: String, in ctx: CGContext, box: CGRect) {
        let font = CTFontCreateUIFontForLanguage(.system, 9, nil)!
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: 12, y: box.height - 18)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
