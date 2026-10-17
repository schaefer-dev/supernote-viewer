import AppKit
import CryptoKit
import SupernoteKit

/// Renders Supernote files to PDFs in a cache shared by Supernote Viewer and Supernote Preview Bridge.
@MainActor
enum RenderCache {
    static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.schaefer.SupernoteViewer", isDirectory: true)
    static let documentsDirectory = cacheRoot.appendingPathComponent("Documents", isDirectory: true)
    static let ocrDirectory = cacheRoot.appendingPathComponent("ocr", isDirectory: true)

    // MARK: - Cache

    /// What a cached PDF was rendered from, to decide whether it is current and whether the
    /// user has since saved changes to it in Preview.
    private struct RenderRecord: Codable {
        var sourceModified: Double
        var sourceSize: Int
        var pdfModified: Double
        /// `PDFRenderer.version` it was rendered with; nil for renders from before it was recorded.
        var rendererVersion: Int?
    }

    /// Returns an up-to-date PDF for `source`, rendering it if needed.
    /// Never overwrites a cached PDF the user modified; uses "Name 2.pdf" etc. instead.
    static func preparePDF(for source: URL) async throws -> URL {
        let fm = FileManager.default
        let (sourceModified, sourceSize) = try signature(of: source)

        let folder = documentsDirectory.appendingPathComponent(shortHash(source.standardizedFileURL.path), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)  // keeps it from cleanup
        let recordsURL = folder.appendingPathComponent(".renders.json")
        var records = (try? JSONDecoder().decode([String: RenderRecord].self, from: Data(contentsOf: recordsURL))) ?? [:]

        let base = baseName(for: source)
        for i in 1...100 {
            let name = i == 1 ? "\(base).pdf" : "\(base) \(i).pdf"
            let pdfURL = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: pdfURL.path) {
                let pdfModified = modificationTime(pdfURL)
                guard let record = records[name], abs(record.pdfModified - pdfModified) < 1 else {
                    continue  // edited in Preview (or unknown): leave it alone
                }
                if record.sourceModified == sourceModified && record.sourceSize == sourceSize
                    && record.rendererVersion == PDFRenderer.version {
                    return pdfURL
                }
            }
            try await render(source, to: pdfURL)
            records[name] = RenderRecord(sourceModified: sourceModified, sourceSize: sourceSize,
                                         pdfModified: modificationTime(pdfURL), rendererVersion: PDFRenderer.version)
            try JSONEncoder().encode(records).write(to: recordsURL, options: .atomic)
            return pdfURL
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Modification time and size of a source file. For `.mark` files the companion PDF's
    /// modification time counts too, so replacing the original PDF also refreshes the render.
    nonisolated static func signature(of source: URL) throws -> (modified: Double, size: Int) {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        if source.pathExtension.lowercased() == "mark" {
            let companion = SNFile.companionPDFURL(forMark: source)
            if let date = (try? FileManager.default.attributesOfItem(atPath: companion.path))?[.modificationDate] as? Date {
                modified = max(modified, date.timeIntervalSinceReferenceDate)
            }
        }
        return (modified, size)
    }

    /// `X.note` → "X", `X.pdf.mark` → "X (annotated)".
    static func baseName(for source: URL) -> String {
        let withoutExtension = source.deletingPathExtension()
        if source.pathExtension.lowercased() == "mark" {
            return withoutExtension.deletingPathExtension().lastPathComponent + " (annotated)"
        }
        return withoutExtension.lastPathComponent
    }

    /// Deletes cached documents not opened for 30 days and recognized text unused for 90 days.
    static func cleanCache(all: Bool = false) {
        let fm = FileManager.default
        func remove(in directory: URL, olderThan days: Double) {
            let cutoff = Date().addingTimeInterval(-days * 86400)
            let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for item in items {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fm.removeItem(at: item) }
            }
        }
        remove(in: documentsDirectory, olderThan: all ? 0 : 30)
        remove(in: ocrDirectory, olderThan: all ? 0 : 90)
    }

    // MARK: - Rendering

    private static func render(_ source: URL, to pdfURL: URL) async throws {
        let progress = ProgressPanel(title: "Opening \(source.lastPathComponent)…")
        progress.showAfterDelay(1)
        defer { progress.close() }

        let options = RenderOptions(vector: true, textLayer: true, ocrCacheDirectory: ocrDirectory) { done, total in
            Task { @MainActor in
                progress.update(text: "Recognizing handwriting… \(done)/\(total)", fraction: Double(done) / Double(max(total, 1)))
            }
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try PDFRenderer.render(contentsOf: source, options: options)
        }.value
        try data.write(to: pdfURL, options: .atomic)
    }

    // MARK: - Helpers

    static func showError(_ error: Error, for url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't open “\(url.lastPathComponent)”"
        alert.informativeText = (error as? SNError)?.description ?? error.localizedDescription
        alert.runModal()
    }

    private static func modificationTime(_ url: URL) -> Double {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return date?.timeIntervalSinceReferenceDate ?? 0
    }

    private static func shortHash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A small floating progress window, shown only for slow renders.
@MainActor
final class ProgressPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let indicator = NSProgressIndicator()
    private var closed = false

    init(title: String) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 76),
                        styleMask: [.titled, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Supernote Viewer"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingMiddle
        indicator.isIndeterminate = true
        indicator.style = .bar

        let stack = NSStackView(views: [label, indicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        panel.contentView = stack
        panel.center()
    }

    func showAfterDelay(_ seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            guard !closed else { return }
            indicator.startAnimation(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
        }
    }

    func update(text: String, fraction: Double) {
        label.stringValue = text
        indicator.isIndeterminate = false
        indicator.doubleValue = fraction * 100
    }

    func close() {
        closed = true
        panel.close()
    }
}
