import AppKit
import PDFKit
import SupernoteKit
import UniformTypeIdentifiers

/// Sumi for Supernote's document window: a PDF view with a thumbnails sidebar, live reload when the
/// source file changes (e.g. after a Supernote sync), and calibrated distance measuring.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    enum Tool: Int {
        case browse = 0
        case calibrate = 1
        case measure = 2
    }

    /// The file the user opened (.note, .mark or .pdf); measurements are stored for it.
    let source: URL
    var onClose: (() -> Void)?

    private static let thumbnailsDefaultsKey = "ShowThumbnails"

    private var pdfDocument: PDFDocument
    private let pdfView = MeasurePDFView()
    private let thumbnailView = PDFThumbnailView()
    private let splitView = NSSplitView()
    private let toolControl = NSSegmentedControl(labels: ["Browse", "Calibrate", "Measure"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var state: MeasureState
    private var selectedID: UUID?
    private var ownAnnotations: [PDFAnnotation] = []

    // Live reload
    private var reloadTimer: Timer?
    private var sourceSignature: (modified: Double, size: Int)?
    private var isReloading = false
    private var lastUpdated: Date?

    private var tool: Tool = .browse {
        didSet {
            toolControl.selectedSegment = tool.rawValue
            pdfView.drawingEnabled = tool != .browse
            pdfView.lineColor = tool == .calibrate ? .systemBlue : .systemRed
            if tool == .browse { selectedID = nil; rebuildAnnotations() }
            updateStatus()
        }
    }

    /// - Parameter measuring: start with a measuring tool instead of Browse.
    init(source: URL, pdfURL: URL, measuring: Bool = false) throws {
        guard let document = PDFDocument(url: pdfURL) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: pdfURL.path])
        }
        self.source = source
        self.pdfDocument = document
        self.state = MeasureStore.state(for: source)
        self.sourceSignature = try? RenderCache.signature(of: source)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 860),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = source.lastPathComponent
        window.representedURL = source
        window.minSize = NSSize(width: 560, height: 400)
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ViewerWindow")

        buildLayout(in: window)
        pdfView.document = pdfDocument
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.onLine = { [weak self] page, start, end in self?.didDrawLine(on: page, from: start, to: end) }
        pdfView.onClick = { [weak self] page, point, tolerance in self?.didClick(on: page, at: point, tolerance: tolerance) }
        pdfView.onDelete = { [weak self] in self?.deleteSelected(nil) }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: pdfView)

        if measuring {
            tool = state.calibrations.isEmpty ? .calibrate : .measure
        } else {
            tool = .browse
        }
        rebuildAnnotations()
        startWatching()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildLayout(in window: NSWindow) {
        toolControl.target = self
        toolControl.action = #selector(toolChanged(_:))
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sidebarButton = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Thumbnails")!,
                                     target: self, action: #selector(toggleThumbnails(_:)))
        sidebarButton.bezelStyle = .texturedRounded
        sidebarButton.toolTip = "Show/Hide Thumbnails (⌥⌘2)"
        let clear = NSButton(title: "Clear All", target: self, action: #selector(clearAll(_:)))
        let export = NSButton(title: "Export PDF…", target: self, action: #selector(exportPDF(_:)))
        let bar = NSStackView(views: [sidebarButton, toolControl, statusLabel, NSView(), clear, export])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 110, height: 146)
        thumbnailView.backgroundColor = .underPageBackgroundColor
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(thumbnailView)
        splitView.addArrangedSubview(pdfView)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        thumbnailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        thumbnailView.isHidden = !UserDefaults.standard.bool(forKey: Self.thumbnailsDefaultsKey)

        let content = NSView()
        for view in [bar, splitView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.initialFirstResponder = pdfView
        DispatchQueue.main.async { [self] in
            if !thumbnailView.isHidden { splitView.setPosition(150, ofDividerAt: 0) }
        }
    }

    @objc func toggleThumbnails(_ sender: Any?) {
        thumbnailView.isHidden.toggle()
        UserDefaults.standard.set(!thumbnailView.isHidden, forKey: Self.thumbnailsDefaultsKey)
        splitView.adjustSubviews()
        if !thumbnailView.isHidden { splitView.setPosition(150, ofDividerAt: 0) }
    }

    // MARK: - Live reload

    /// Polls the source every 2 s. Polling (rather than file system events) also works for files
    /// in synced, cloud or network folders that are replaced from outside.
    private func startWatching() {
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForChanges() }
        }
    }

    private func checkForChanges() {
        guard !isReloading, let current = try? RenderCache.signature(of: source) else { return }
        if let known = sourceSignature, known.modified == current.modified, known.size == current.size { return }
        sourceSignature = current
        // PDFs are shown directly; Supernote files are re-rendered through the shared cache.
        guard source.pathExtension.lowercased() != "pdf" else { return reload(from: source) }
        isReloading = true
        Task { @MainActor in
            defer { isReloading = false }
            do {
                reload(from: try await RenderCache.preparePDF(for: source))
            } catch {
                NSLog("Sumi: reloading %@ failed: %@", source.path, "\(error)")
            }
        }
    }

    private func reload(from pdfURL: URL) {
        guard let document = PDFDocument(url: pdfURL) else { return }
        let pageIndex = pdfView.currentPage.map { pdfDocument.index(for: $0) } ?? 0
        let autoScales = pdfView.autoScales, scale = pdfView.scaleFactor

        ownAnnotations.removeAll()  // they belong to the old document
        pdfDocument = document
        pdfView.document = document
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        if let page = document.page(at: min(pageIndex, max(document.pageCount - 1, 0))) { pdfView.go(to: page) }
        lastUpdated = Date()
        rebuildAnnotations()
        NSLog("Sumi: reloaded %@ (%d pages)", source.lastPathComponent, document.pageCount)
    }

    // MARK: - Interaction

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        tool = Tool(rawValue: sender.selectedSegment) ?? .browse
    }

    @objc private func pageChanged(_ notification: Notification) {
        updateStatus()
    }

    private func didDrawLine(on page: PDFPage, from start: CGPoint, to end: CGPoint) {
        let pageIndex = pdfDocument.index(for: page)
        switch tool {
        case .browse:
            break
        case .measure:
            let line = MeasureLine(pageIndex: pageIndex, start: start, end: end)
            state.measurements.append(line)
            selectedID = line.id
            commit()
        case .calibrate:
            askForLength { [weak self] meters in
                guard let self, let meters else { return }
                let calibration = Calibration(pageIndex: pageIndex, start: start, end: end, meters: meters)
                self.state.calibrate(calibration)
                self.selectedID = nil
                self.commit()
                self.tool = .measure
            }
        }
    }

    private func didClick(on page: PDFPage, at point: CGPoint, tolerance: CGFloat) {
        let pageIndex = pdfDocument.index(for: page)
        var best: (id: UUID, distance: CGFloat)?
        let lines = state.measurements.filter { $0.pageIndex == pageIndex }.map { ($0.id, $0.start, $0.end) }
            + state.calibrations.filter { $0.pageIndex == pageIndex }.map { ($0.id, $0.start, $0.end) }
        for (id, a, b) in lines {
            let d = Self.distance(from: point, toSegment: a, b)
            if d <= tolerance && d < (best?.distance ?? .infinity) { best = (id, d) }
        }
        selectedID = best?.id
        rebuildAnnotations()
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard let id = selectedID else { NSSound.beep(); return }
        state.remove(id: id)
        selectedID = nil
        commit()
        if state.calibrations.isEmpty && tool == .measure { tool = .calibrate }
    }

    @objc func clearAll(_ sender: Any?) {
        guard !state.calibrations.isEmpty || !state.measurements.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all measurements and the calibration?"
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.state = MeasureState()
            self.selectedID = nil
            self.commit()
            if self.tool == .measure { self.tool = .calibrate }
        }
    }

    @objc func zoomToFit(_ sender: Any?) {
        pdfView.autoScales = true
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(RenderCache.baseName(for: source)) (measured).pdf"
        panel.directoryURL = source.pathExtension.lowercased() == "pdf"
            ? source.deletingLastPathComponent()
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let selection = self.selectedID
            self.selectedID = nil
            self.rebuildAnnotations()
            if !self.pdfDocument.write(to: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save “\(url.lastPathComponent)”"
                alert.beginSheetModal(for: window)
            }
            self.selectedID = selection
            self.rebuildAnnotations()
        }
    }

    func windowWillClose(_ notification: Notification) {
        reloadTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    // MARK: - Calibration input

    private func askForLength(completion: @escaping (Double?) -> Void) {
        guard let window else { return completion(nil) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. 2,23 m · 223 cm · 2230 mm"
        let alert = NSAlert()
        alert.messageText = "How long is this line in reality?"
        alert.informativeText = "Enter the real length. Meters are assumed if you don't give a unit."
        alert.accessoryView = field
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            if let meters = Length.parse(field.stringValue) {
                completion(meters)
            } else {
                let error = NSAlert()
                error.messageText = "“\(field.stringValue)” isn't a length"
                error.informativeText = "Try something like 2,23 m, 223 cm or 2230 mm, then draw the reference line again."
                if let window = self?.window { error.beginSheetModal(for: window) }
                completion(nil)
            }
        }
    }

    // MARK: - Annotations

    private func commit() {
        MeasureStore.save(state, for: source)
        rebuildAnnotations()
    }

    /// Recreates all measurement annotations from `state`.
    private func rebuildAnnotations() {
        for annotation in ownAnnotations { annotation.page?.removeAnnotation(annotation) }
        ownAnnotations.removeAll()

        for calibration in state.calibrations {
            add(from: calibration.start, to: calibration.end, pageIndex: calibration.pageIndex,
                text: "Ref \(Length.format(calibration.meters))", color: .systemBlue,
                selected: calibration.id == selectedID)
        }
        for line in state.measurements {
            let text = state.meters(of: line).map { Length.format($0) } ?? "calibrate first"
            add(from: line.start, to: line.end, pageIndex: line.pageIndex, text: text, color: .systemRed,
                selected: line.id == selectedID)
        }
        updateStatus()
    }

    private func add(from start: CGPoint, to end: CGPoint, pageIndex: Int, text: String, color: NSColor, selected: Bool) {
        guard let page = pdfDocument.page(at: pageIndex) else { return }
        let pageSize = page.bounds(for: .cropBox).size
        let width = max(0.6, min(pageSize.width, pageSize.height) / 600) * (selected ? 2 : 1)
        let drawColor = selected ? NSColor.systemOrange : color

        let line = MeasurePDFView.lineAnnotation(from: start, to: end, color: drawColor, width: width, arrows: true)
        page.addAnnotation(line)
        ownAnnotations.append(line)

        let font = NSFont.systemFont(ofSize: max(6, min(pageSize.width, pageSize.height) / 75), weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let label = PDFAnnotation(bounds: CGRect(x: mid.x - size.width / 2 - 3, y: mid.y - size.height / 2 - 1,
                                                 width: size.width + 6, height: size.height + 2),
                                  forType: .freeText, withProperties: nil)
        label.contents = text
        label.font = font
        label.fontColor = drawColor
        label.color = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        let border = PDFBorder()
        border.lineWidth = 0
        label.border = border
        label.isReadOnly = true
        page.addAnnotation(label)
        ownAnnotations.append(label)
    }

    private func updateStatus() {
        let pageIndex = pdfView.currentPage.map { pdfDocument.index(for: $0) } ?? 0
        var parts: [String] = []
        if let scale = state.scale(forPage: pageIndex) {
            // 1 cm on the page = 72 / 2.54 PDF points.
            var text = "Scale: 1 cm on plan = \(Length.format(scale.metersPerPoint * 72 / 2.54))"
            if scale.fromPage != pageIndex { text += " (from page \(scale.fromPage + 1))" }
            parts.append(text)
        } else {
            parts.append("Not calibrated")
        }
        switch tool {
        case .browse: parts.append("Choose Calibrate or Measure to draw")
        case .calibrate: parts.append("Drag along a known length, then enter its real size")
        case .measure: parts.append("Drag to measure · ⇧ for straight lines · click + ⌫ to delete")
        }
        if let lastUpdated {
            parts.append("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
        }
        statusLabel.stringValue = parts.joined(separator: " — ")
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
