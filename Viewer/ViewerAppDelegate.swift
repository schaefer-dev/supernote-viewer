import AppKit
import PDFKit
import SwiftUI
import SupernoteKit
import UniformTypeIdentifiers

/// Sumi for Supernote: opens .note, .mark and PDF files in its own windows (thumbnails, live reload,
/// measuring), or, with the Preview setting, renders .note/.mark files to PDF and hands them to Preview.
/// Also provides the "Measure in Sumi for Supernote" Finder service.
@main
final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    private var receivedFiles = false
    private var pendingJobs = 0
    private var windows: [ViewerWindowController] = []
    private var settingsWindow: NSWindow?
    private var openPanel: NSOpenPanel?

    static func main() {
        let app = NSApplication.shared
        let delegate = ViewerAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        // Registered early so a service request that launched the app is delivered.
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RenderCache.cleanCache()
        #if DEBUG
        // Development: running from Xcode with a .note/.mark path as launch argument (see the scheme
        // in project.yml) opens it freshly rendered in Preview, so renderer changes show without installing.
        let files = ProcessInfo.processInfo.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
            .filter { Self.isSupernoteFile($0) && FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty {
            receivedFiles = true
            openInPreview(files, forceRender: true)
        }
        #endif
        // Files arrive via application(_:open:) right after launch; without any, offer to open one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !receivedFiles { openDocument(nil) }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        receivedFiles = true
        // Double-clicked .note/.mark files follow the "Open Supernote files in" setting; PDFs (Open With)
        // always open here.
        if OpenMode.current == .preview {
            let supernote = urls.filter(Self.isSupernoteFile)
            let others = urls.filter { !Self.isSupernoteFile($0) }
            if !supernote.isEmpty { openInPreview(supernote, forceRender: false) }
            if !others.isEmpty { openWindows(for: others, measuring: false) }
        } else {
            openWindows(for: urls, measuring: false)
        }
    }

    private static func isSupernoteFile(_ url: URL) -> Bool {
        ["note", "mark"].contains(url.pathExtension.lowercased())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    /// Finder service "Measure in Sumi for Supernote" (NSServices in Info.plist).
    @objc func measureFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receivedFiles = true
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        openWindows(for: urls, measuring: true)
    }

    @objc func openDocument(_ sender: Any?) {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType("dev.schaefer.supernote.note"), UTType("dev.schaefer.supernote.mark"), .pdf]
            .compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        // Not modal, so the menu (e.g. Settings…) stays usable while the panel is open.
        openPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            openPanel = nil
            if response == .OK {
                openWindows(for: panel.urls, measuring: false)
            } else {
                quitIfIdle()
            }
        }
    }

    // MARK: - Windows

    private func openWindows(for urls: [URL], measuring: Bool) {
        pendingJobs += 1
        Task { @MainActor in
            for url in urls {
                // Bring an already open window to the front instead of opening a second one.
                if let existing = windows.first(where: { $0.source.standardizedFileURL == url.standardizedFileURL }) {
                    existing.showWindow(nil)
                    continue
                }
                do {
                    // Supernote files are shown as the same rendered PDF that Preview mode hands to Preview.
                    let pdfURL = url.pathExtension.lowercased() == "pdf" ? url : try await RenderCache.preparePDF(for: url)
                    let controller = try ViewerWindowController(source: url, pdfURL: pdfURL, measuring: measuring)
                    controller.onClose = { [weak self, weak controller] in
                        self?.windows.removeAll { $0 === controller }
                        // Let the window finish closing before possibly quitting.
                        DispatchQueue.main.async { self?.quitIfIdle() }
                    }
                    windows.append(controller)
                    controller.showWindow(nil)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    NSApp.activate(ignoringOtherApps: true)
                } catch {
                    RenderCache.showError(error, for: url)
                }
            }
            pendingJobs -= 1
            quitIfIdle()
        }
    }

    // MARK: - Preview

    /// Renders .note/.mark files to PDFs and opens them in Preview.app.
    private func openInPreview(_ urls: [URL], forceRender: Bool) {
        pendingJobs += 1
        Task { @MainActor in
            var pdfs: [URL] = []
            for url in urls {
                do {
                    pdfs.append(try await RenderCache.preparePDF(for: url, forceRender: forceRender))
                } catch {
                    RenderCache.showError(error, for: url)
                }
            }
            if !pdfs.isEmpty { await Self.handToPreview(pdfs) }
            pendingJobs -= 1
            quitIfIdle()
        }
    }

    private static func handToPreview(_ pdfs: [URL]) async {
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

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.settingsWindow = nil
                    DispatchQueue.main.async { self?.quitIfIdle() }
                }
            }
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func quitIfIdle() {
        if pendingJobs == 0 && windows.isEmpty && settingsWindow == nil && openPanel == nil {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Menu

    private static func makeMainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
        let main = NSMenu()
        main.addItem(submenu("Sumi for Supernote", [
            item("Settings…", #selector(ViewerAppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide Sumi for Supernote", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit Sumi for Supernote", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("Open…", #selector(ViewerAppDelegate.openDocument(_:)), "o"),
            .separator(),
            item("Export PDF…", #selector(ViewerWindowController.exportPDF(_:)), "e"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Delete Measurement", #selector(ViewerWindowController.deleteSelected(_:)), "\u{8}", []),
            item("Clear All Measurements…", #selector(ViewerWindowController.clearAll(_:)), ""),
        ]))
        main.addItem(submenu("View", [
            item("Show/Hide Thumbnails", #selector(ViewerWindowController.toggleThumbnails(_:)), "2", [.command, .option]),
            .separator(),
            item("Zoom In", #selector(PDFView.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(PDFView.zoomOut(_:)), "-"),
            item("Zoom to Fit", #selector(ViewerWindowController.zoomToFit(_:)), "0"),
        ]))
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)
        return main
    }
}
