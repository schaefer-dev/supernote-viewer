import AppKit
import SupernoteKit
import SwiftUI

/// Supernote Preview Bridge: opening a .note or .mark file renders it to a PDF, hands it to
/// Preview and quits. Launched on its own, it shows a short info window instead.
@main
final class BridgeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var receivedFiles = false
    private var pendingJobs = 0
    private var infoWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = BridgeAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RenderCache.cleanCache()

        // For development; if given a CLI argument clear the cache and re-render
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.isEmpty {
            let url = URL(fileURLWithPath: arguments[1])
            RenderCache.cleanCache(all: true)
            application(NSApplication.shared, open: [url])
            
        }
        
        // Files arrive via application(_:open:) right after launch; without any, show the info window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !receivedFiles { showInfoWindow() }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        receivedFiles = true
        pendingJobs += 1
        Task { @MainActor in
            var pdfs: [URL] = []
            for url in urls {
                do {
                    pdfs.append(try await RenderCache.preparePDF(for: url))
                } catch {
                    RenderCache.showError(error, for: url)
                }
            }
            if !pdfs.isEmpty { await openInPreview(pdfs) }
            pendingJobs -= 1
            quitIfIdle()
        }
    }

    private func openInPreview(_ pdfs: [URL]) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            pdfs.forEach { NSWorkspace.shared.open($0) }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.open(pdfs, withApplicationAt: preview, configuration: configuration) { _, error in
                if let error {
                    Task { @MainActor in RenderCache.showError(error, for: pdfs[0]) }
                }
                continuation.resume()
            }
        }
    }

    private func quitIfIdle() {
        if pendingJobs == 0 && infoWindow == nil {
            NSApp.terminate(nil)
        }
    }

    private func showInfoWindow() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: InfoView()))
        window.title = "Supernote Preview Bridge"
        window.styleMask = [.titled, .closable]
        window.delegate = self
        window.center()
        infoWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        infoWindow = nil
        DispatchQueue.main.async { self.quitIfIdle() }
    }
}

struct InfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supernote Preview Bridge").font(.title2.bold())
            Text("Opens .note and .pdf.mark files in Preview, with sharp handwriting you can search, select and highlight.")
            Text("Prefer Supernote's own window with thumbnails, live reload and measuring? Make Supernote Viewer the default instead: in Finder, select a .note file → Get Info → Open with → Supernote Viewer → Change All… (and the same for a .mark file). Switch back the same way.")
                .foregroundStyle(.secondary)
            Text("Preview opens a generated copy. To keep your Preview annotations, use File → Export or Duplicate. If the notebook changes, the copy is regenerated, but a copy you saved changes to is never overwritten.")
                .foregroundStyle(.secondary)
            Text("For .mark files, keep the original PDF next to it (X.pdf.mark → X.pdf).")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480)
        .fixedSize()
    }
}
