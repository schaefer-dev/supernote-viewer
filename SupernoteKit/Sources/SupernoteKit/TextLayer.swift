import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import Vision

/// A recognized handwritten word with its box in normalized page coordinates (origin bottom-left).
public struct RecognizedWord: Codable {
    public let text: String
    public let box: CGRect
}

/// Handwriting recognition (Vision) and an invisible PDF text layer, so handwriting can be
/// searched, selected, copied and highlighted in Preview.
public enum TextLayer {
    public static var recognitionLanguages = ["de-DE", "en-US"]
    private static let cacheVersion = "2"

    /// Recognizes every page in parallel, keyed by page number. Pages whose content hash is in
    /// `cacheDirectory` are not recognized again.
    public static func recognize(file: SNFile, cacheDirectory: URL?,
                                 progress: ((_ done: Int, _ total: Int) -> Void)? = nil,
                                 maximumConcurrentPageWork: Int = 4,
                                 isCancelled: @escaping () -> Bool = { false },
                                 recognitionError: ((Int, Error) -> Void)? = nil) -> [Int: [RecognizedWord]] {
        let lock = NSLock()
        var results: [Int: [RecognizedWord]] = [:]
        var done = 0
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, maximumConcurrentPageWork)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        for page in file.pages {
            if isCancelled() { break }
            queue.addOperation {
                guard !isCancelled() else { return }
                autoreleasepool {
                    do {
                        let words = try cachedRecognition(page: page, file: file, cacheDirectory: cacheDirectory)
                        lock.withLock { results[page.number] = words }
                    } catch { recognitionError?(page.number, error) }
                    let n = lock.withLock { done += 1; return done }
                    progress?(n, file.pages.count)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return results
    }

    /// Failed recognition is never persisted as a successful empty page.
    static func cachedRecognition(page: SNPage, file: SNFile, cacheDirectory: URL?,
                                  recognizeImage: (CGImage) throws -> [RecognizedWord] = recognizeThrowing) throws -> [RecognizedWord] {
        let cacheURL = cacheDirectory.flatMap { dir in
            contentHash(of: page, in: file).map { dir.appendingPathComponent("\($0).json") }
        }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let words = try? JSONDecoder().decode([RecognizedWord].self, from: data) { return words }
        guard let image = LayerCompositor.render(page: page, in: file, background: .white,
                                                 include: { $0.name != "BGLAYER" }) else {
            throw SNError.malformed("could not prepare page \(page.number) for recognition")
        }
        let words = try recognizeImage(image)
        if let cacheURL, let data = try? JSONEncoder().encode(words) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return words
    }

    /// Recognizes handwriting in an image, returning one entry per whitespace-separated word.
    public static func recognize(image: CGImage) -> [RecognizedWord] {
        (try? recognizeThrowing(image: image)) ?? []
    }

    public static func recognizeThrowing(image: CGImage) throws -> [RecognizedWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = recognitionLanguages.filter(supported.contains)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        var words: [RecognizedWord] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var wordRanges: [Range<String.Index>] = []
            var start: String.Index?
            for i in text.indices {
                if text[i].isWhitespace {
                    if let s = start { wordRanges.append(s..<i); start = nil }
                } else if start == nil {
                    start = i
                }
            }
            if let s = start { wordRanges.append(s..<text.endIndex) }

            // Check marks, checkboxes and bullets come back as single symbols ("V", "/", "•");
            // they only add noise to search results.
            for range in wordRanges where text[range].filter({ $0.isLetter || $0.isNumber }).count >= 2 {
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append(RecognizedWord(text: String(text[range]), box: box))
            }
        }
        return words
    }

    /// Draws words as invisible text, each stretched to its box. `rect` is where the device page
    /// sits in the PDF page.
    public static func draw(_ words: [RecognizedWord], in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for word in words {
            let box = CGRect(x: rect.minX + word.box.minX * rect.width, y: rect.minY + word.box.minY * rect.height,
                             width: word.box.width * rect.width, height: word.box.height * rect.height)
            guard box.width > 0.5, box.height > 0.5 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.9, nil)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let wordWidth = CTLineGetTypographicBounds(
                CTLineCreateWithAttributedString(NSAttributedString(string: word.text, attributes: attributes)),
                nil, nil, nil)
            guard wordWidth > 0 else { continue }
            // Trailing space so text extraction keeps word boundaries.
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word.text + " ", attributes: attributes))
            // Stretch via the CTM (not the text matrix) so glyph positions scale with the glyphs;
            // otherwise text extraction sees gaps between letters.
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.minY + CTFontGetDescent(font) * 0.5)
            ctx.scaleBy(x: box.width / wordWidth, y: 1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Hash of everything that affects a page's handwriting.
    static func contentHash(of page: SNPage, in file: SNFile) -> String? {
        var hasher = SHA256()
        hasher.update(data: Data("v\(cacheVersion)|\(recognitionLanguages.joined(separator: ","))|\(page.width)x\(page.height)".utf8))
        var any = false
        if let address = page.metadata.address("TOTALPATH"), let block = try? file.block(at: address) {
            hasher.update(data: block); any = true
        }
        for layer in page.visibleLayers(fileType: file.fileType) where layer.name != "BGLAYER" {
            if let address = layer.bitmapAddress, let block = try? file.block(at: address) {
                hasher.update(data: block); any = true
            }
        }
        guard any else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
