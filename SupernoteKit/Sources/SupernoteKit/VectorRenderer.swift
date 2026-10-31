import CoreGraphics
import Foundation

/// Draws strokes from TOTALPATH as filled vector outlines.
enum VectorRenderer {
    /// Color codes that the device draws as solid (non anti-aliased) pixels.
    /// Indexed by color code, since it is checked for every pixel of a layer.
    private static let solidCodes: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for code in [0x61, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x9d, 0x9e, 0xc9, 0xca] { table[code] = true }
        return table
    }()

    /// Draws one layer's ink strokes. The context must map page pixels (origin top-left, y down)
    /// onto the page. Markers are drawn first, as one transparency group per color, so overlapping
    /// highlighter strokes don't darken each other (the device bitmap is flat too).
    static func draw(_ strokes: [SNStroke], in ctx: CGContext, file: SNFile) {
        let table = LayerCompositor.inkTable(x2: file.usesX2Colors, markFile: file.fileType == .mark)
        let ink = strokes.filter(\.isInk)

        var groups: [UInt8: [CGPath]] = [:]  // alpha -> translucent strokes
        var opaque: [(path: CGPath, gray: CGFloat)] = []
        for stroke in ink {
            let (gray, alpha) = color(of: stroke, table: table)
            if alpha == 255 {
                opaque.append((stroke.path, CGFloat(gray) / 255))
            } else {
                groups[alpha, default: []].append(stroke.path)
            }
        }

        // Translucent ink is black at alpha (1 - gray), equivalent to multiplying by the gray.
        for (alpha, paths) in groups.sorted(by: { $0.key < $1.key }) {
            ctx.saveGState()
            ctx.setAlpha(CGFloat(alpha) / 255)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(gray: 0, alpha: 1)
            for path in paths {
                ctx.addPath(path)
                ctx.fillPath(using: .evenOdd)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for (path, gray) in opaque {
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
    }

    /// Premultiplied (gray, alpha) for a stroke, using the same ink model as the bitmap compositor.
    private static func color(of stroke: SNStroke, table: [LayerCompositor.Ink]) -> (gray: UInt8, alpha: UInt8) {
        let code = UInt8(clamping: stroke.color)
        if code == 0x65 || code == 0xfe { return (255, 255) }  // white ink
        var ink = table[Int(code)]
        if stroke.isMarker && ink.alpha == 255 {
            ink = .multiply(ink.gray)
        }
        if ink.alpha == 0 { ink = .opaque(0) }
        return ink.alpha == 255 ? (ink.gray, 255) : (0, ink.alpha)
    }

    /// Checks that the strokes reproduce a layer's bitmap: at most max(50 px, 0.5%) of its solid
    /// ink may be left uncovered, and at most max(50 px, 1%) of it may be painted where the bitmap is
    /// empty. Fails for content TOTALPATH doesn't describe (images) or misdescribes. Pixels inside
    /// `ignoring` (text boxes, whose glyphs are only in the bitmap) don't count as uncovered.
    static func covers(_ strokes: [SNStroke], codes: [UInt8], width: Int, height: Int,
                       ignoring rects: [CGRect] = []) -> Bool {
        var mask = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = mask.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Memory row 0 is the top row; flip so page pixel y maps to memory row y.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            for stroke in strokes where stroke.isInk {
                ctx.addPath(stroke.path)
                ctx.fillPath(using: .evenOdd)
            }
            return true
        }
        guard drawn else { return false }

        var ignored = [Bool](repeating: false, count: rects.isEmpty ? 0 : width * height)
        for rect in rects {
            let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !r.isNull, !r.isEmpty else { continue }
            for y in Int(r.minY)..<Int(r.maxY) {
                for x in Int(r.minX)..<Int(r.maxX) { ignored[y * width + x] = true }
            }
        }

        var solid = 0, uncovered = 0, overpainted = 0
        for i in 0..<min(codes.count, mask.count) {
            let code = codes[i]
            if solidCodes[Int(code)] {
                solid += 1
                if mask[i] == 0 && (ignored.isEmpty || !ignored[i]) { uncovered += 1 }
            } else if code == RLEDecoder.transparent && mask[i] >= 128 {
                overpainted += 1
            }
        }
        return uncovered <= max(50, solid / 200) && overpainted <= max(50, solid / 100)
    }
}
