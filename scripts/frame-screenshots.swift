// Frames raw App Store screenshots with a caption on the Sumi washi background.
//
//   swift scripts/frame-screenshots.swift <appstore-dir>
//
// Reads   <appstore-dir>/screenshots/raw/<device>/<name>.png   (from scripts/appstore-screenshots.sh)
//         <appstore-dir>/screenshots/captions.json
// Writes  <appstore-dir>/screenshots/final/<device>/<name>.png  at the exact App Store size, without alpha.
//
// captions.json maps a screenshot name to its caption; a device-specific entry ("ipad/05-library")
// takes precedence. A title ending in "." gets the indigo full stop of the wordmark.
//   { "01-reader": { "title": "Your notes, in ink.", "subtitle": "Crisp vector handwriting from every notebook" } }
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Caption: Decodable { let title: String; let subtitle: String? }

/// App Store sizes for the 6.9" iPhone and 13" iPad display classes.
let canvases: [String: CGSize] = ["iphone": CGSize(width: 1320, height: 2868), "ipad": CGSize(width: 2064, height: 2752)]

// Palette from Artwork/sumi/README.md.
let washi = NSColor(srgbRed: 0xED / 255, green: 0xE9 / 255, blue: 0xDF / 255, alpha: 1)
let sumi = NSColor(srgbRed: 0x15 / 255, green: 0x15 / 255, blue: 0x15 / 255, alpha: 1)
let usuzumi = NSColor(srgbRed: 0x6E / 255, green: 0x6B / 255, blue: 0x64 / 255, alpha: 1)
let indigo = NSColor(srgbRed: 0x2B / 255, green: 0x4C / 255, blue: 0x8C / 255, alpha: 1)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fail("usage: frame-screenshots.swift <appstore-dir>") }
let root = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath).appendingPathComponent("screenshots")
let rawRoot = root.appendingPathComponent("raw"), finalRoot = root.appendingPathComponent("final")
guard let captionData = try? Data(contentsOf: root.appendingPathComponent("captions.json")),
      let captions = try? JSONDecoder().decode([String: Caption].self, from: captionData) else {
    fail("Missing or invalid \(root.path)/captions.json")
}
// The app icon's washi layer gives the background its paper fibre.
let texture: CGImage? = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ViewerIOS/AppIcon.icon/Assets/paper.png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}()

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func titleString(_ text: String, size: CGFloat) -> NSAttributedString {
    let font = NSFont(name: "Didot-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineHeightMultiple = 0.95
    let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: sumi, .paragraphStyle: paragraph])
    if text.hasSuffix(".") { string.addAttribute(.foregroundColor, value: indigo, range: NSRange(location: string.length - 1, length: 1)) }
    return string
}

func subtitleString(_ text: String, size: CGFloat) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineHeightMultiple = 1.1
    return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular),
                                                         .foregroundColor: usuzumi, .paragraphStyle: paragraph])
}

func frame(_ shot: CGImage, caption: Caption, canvas: CGSize, isPad: Bool) -> CGImage {
    let width = Int(canvas.width), height = Int(canvas.height)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let bounds = CGRect(origin: .zero, size: canvas)
    context.setFillColor(washi.cgColor); context.fill(bounds)
    if let texture {
        context.saveGState(); context.setAlpha(0.55); context.setBlendMode(.multiply)
        let tile = CGFloat(texture.width) * (canvas.width / 1320)
        var y: CGFloat = 0
        while y < canvas.height {
            var x: CGFloat = 0
            while x < canvas.width { context.draw(texture, in: CGRect(x: x, y: y, width: tile, height: tile)); x += tile }
            y += tile
        }
        context.restoreGState()
    }

    // Caption block at the top (Core Graphics origin is bottom-left).
    let margin = canvas.width * (isPad ? 0.10 : 0.08)
    let titleSize = canvas.width * (isPad ? 0.052 : 0.082)
    let subtitleSize = canvas.width * (isPad ? 0.022 : 0.036)
    let textWidth = canvas.width - 2 * margin
    let top = canvas.height * (isPad ? 0.055 : 0.075)
    let title = titleString(caption.title, size: titleSize)
    let titleHeight = ceil(title.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
    let subtitle = caption.subtitle.map { subtitleString($0, size: subtitleSize) }
    let subtitleHeight = subtitle.map { ceil($0.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height) } ?? 0
    let gap = subtitle == nil ? 0 : titleSize * 0.35

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let titleRect = CGRect(x: margin, y: canvas.height - top - titleHeight, width: textWidth, height: titleHeight)
    title.draw(with: titleRect, options: [.usesLineFragmentOrigin])
    if let subtitle {
        subtitle.draw(with: CGRect(x: margin, y: titleRect.minY - gap - subtitleHeight, width: textWidth, height: subtitleHeight),
                      options: [.usesLineFragmentOrigin])
    }
    NSGraphicsContext.restoreGraphicsState()

    // The screenshot below the caption, rounded like the device display, running off the bottom edge.
    let captionBottom = canvas.height - top - titleHeight - gap - subtitleHeight
    let shotTop = captionBottom - canvas.height * (isPad ? 0.04 : 0.045)
    let shotWidth = canvas.width * (isPad ? 0.80 : 0.84)
    let shotHeight = shotWidth * CGFloat(shot.height) / CGFloat(shot.width)
    let shotRect = CGRect(x: (canvas.width - shotWidth) / 2, y: shotTop - shotHeight, width: shotWidth, height: shotHeight)
    let radius = shotWidth * (isPad ? 0.035 : 0.12)
    let path = CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas.width * 0.008), blur: canvas.width * 0.04,
                      color: NSColor(white: 0, alpha: 0.28).cgColor)
    context.addPath(path); context.setFillColor(sumi.cgColor); context.fillPath()
    context.restoreGState()

    // A thin ink bezel, then the screen itself.
    let bezel = shotWidth * 0.012
    context.saveGState()
    context.addPath(CGPath(roundedRect: shotRect.insetBy(dx: -bezel, dy: -bezel), cornerWidth: radius + bezel, cornerHeight: radius + bezel, transform: nil))
    context.setFillColor(sumi.cgColor); context.fillPath()
    context.addPath(path); context.clip()
    context.interpolationQuality = .high
    context.draw(shot, in: shotRect)
    context.restoreGState()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("Cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Cannot write \(url.path)") }
}

let fileManager = FileManager.default
var written = 0
for (device, canvas) in canvases.sorted(by: { $0.key < $1.key }) {
    let rawDirectory = rawRoot.appendingPathComponent(device)
    guard let files = try? fileManager.contentsOfDirectory(at: rawDirectory, includingPropertiesForKeys: nil) else { continue }
    let output = finalRoot.appendingPathComponent(device)
    try? fileManager.removeItem(at: output)
    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    for file in files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = file.deletingPathExtension().lastPathComponent
        guard let caption = captions["\(device)/\(name)"] ?? captions[name] else {
            print("skip \(device)/\(name): no caption"); continue
        }
        guard let shot = loadImage(file) else { fail("Cannot read \(file.path)") }
        writePNG(frame(shot, caption: caption, canvas: canvas, isPad: device == "ipad"), to: output.appendingPathComponent(file.lastPathComponent))
        print("wrote \(device)/\(file.lastPathComponent)")
        written += 1
    }
}
if written == 0 { fail("No screenshots framed. Run scripts/appstore-screenshots.sh first.") }
