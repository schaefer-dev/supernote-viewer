// Writes an app's icon as macOS renders it, glass included: a 512 px .png (README banner) or an
// .icns (DMG volume icon).
//   swift Artwork/app-icon.swift "<path>/Sumi for Supernote.app" <out>.png|<out>.icns
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: app-icon.swift <app> <out.png|out.icns>\n".data(using: .utf8)!)
    exit(2)
}
// icon(forFile:) quietly returns a generic document icon for paths it can't resolve, relative ones included.
let app = URL(fileURLWithPath: args[1]).standardizedFileURL.path
guard FileManager.default.fileExists(atPath: app + "/Contents/Info.plist") else {
    FileHandle.standardError.write("error: no app at \(app)\n".data(using: .utf8)!)
    exit(1)
}
let icon = NSWorkspace.shared.icon(forFile: app)
let out = URL(fileURLWithPath: args[2])

func png(_ pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

if out.pathExtension == "png" {
    try png(512, to: out)
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try png(points * scale, to: iconset.appendingPathComponent(
            "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
