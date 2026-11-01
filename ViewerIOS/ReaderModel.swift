import Foundation
import Observation
import PDFKit
import UIKit

private final class SearchGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var id = UUID()
    var value: UUID { lock.withLock { id } }
    func advance() { lock.withLock { id = UUID() } }
}

/// SwiftUI removes the reader's PDF view while another document loads and inserts it again
/// without a size. PDFView lays a document out anew the first time it gets a size, which scrolls
/// back to the first page and drops any page set before. Navigation requested in that state waits
/// here and runs once the view is on screen and laid out.
final class ReaderPDFView: PDFView {
    private var pending: (() -> Void)?
    /// True while a requested position waits for layout; page reports until then are PDFKit's own.
    var isAwaitingLayout: Bool { pending != nil }
    var isReady: Bool { window != nil && !bounds.isEmpty }
    func navigate(_ action: @escaping () -> Void) {
        if isReady && pending == nil { action() } else { pending = action; setNeedsLayout() }
    }
    func cancelPendingNavigation() { pending = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); if pending != nil { setNeedsLayout() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard pending != nil, isReady else { return }
        // PDFKit finishes its own layout, including the scroll to the top, after this pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isReady, let action = self.pending else { return }
            self.pending = nil
            action()
        }
    }
}

@Observable @MainActor final class ReaderModel: NSObject, PDFDocumentDelegate {
    let view = ReaderPDFView()
    @ObservationIgnored nonisolated private let searches = SearchGeneration()
    var query = ""
    var results: [PDFSelection] = []
    /// The match the find bar is on, as an index into `results`.
    var current: Int?
    /// Searching runs only while the find bar is open, so a reloaded document never jumps to a match.
    var findActive = false
    /// After the recognized PDF replaces the preview, find resumes at the page it was on.
    @ObservationIgnored private var resumePage: Int?
    var searching = false
    var document: PDFDocument?
    var titles: [Title] = []
    var page = 0
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    var pageChanged: ((Int) -> Void)?
    /// Called after a document's titles are read, including the updated PDF after recognition.
    var titlesChanged: (() -> Void)?
    private var workspace: Workspace?
    struct Title: Identifiable {
        let id = UUID()
        let label: String
        let page: Int
        let depth: Int
    }
    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.view.isAwaitingLayout, let document = self.document, let current = self.view.currentPage else { return }
                self.page = document.index(for: current)
                self.pageChanged?(self.page)
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func reset() {
        searches.advance()
        document?.cancelFindString(); document?.delegate = nil
        view.cancelPendingNavigation()
        document = nil; view.document = nil; workspace = nil; results = []; current = nil; resumePage = nil; titles = []; page = 0; query = ""; searching = false
    }
    func replace(_ document: PDFDocument, page requestedPage: Int, workspace: Workspace? = nil) {
        guard document !== self.document else { return }
        searches.advance()
        let replacing = self.document != nil
        let destination = view.currentDestination
        let zoom = view.scaleFactor / max(view.scaleFactorForSizeToFit, 0.01)
        self.document?.cancelFindString()
        self.document?.delegate = nil
        resumePage = currentMatchPage
        results = []; current = nil; view.highlightedSelections = []; view.clearSelection()
        self.document = document; document.delegate = self
        view.document = document
        self.workspace = workspace
        page = min(max(0, requestedPage), max(0, document.pageCount - 1))
        if let newPage = document.page(at: page) {
            let view = self.view
            view.navigate {
                guard view.document === document else { return }
                if replacing, let destination { view.go(to: PDFDestination(page: newPage, at: destination.point)) }
                else { view.go(to: newPage) }
                if replacing { view.scaleFactor = max(view.minScaleFactor, min(view.maxScaleFactor, view.scaleFactorForSizeToFit * zoom)) }
            }
        }
        titles = Self.titles(in: document)
        titlesChanged?()
        search()
    }
    static func titles(in document: PDFDocument) -> [Title] {
        var result: [Title] = []
        func visit(_ outline: PDFOutline, depth: Int) {
            if let label = outline.label, let page = outline.destination?.page {
                result.append(Title(label: label, page: document.index(for: page), depth: depth))
            }
            for index in 0..<outline.numberOfChildren { if let child = outline.child(at: index) { visit(child, depth: depth + 1) } }
        }
        if let root = document.outlineRoot {
            for index in 0..<root.numberOfChildren { if let child = root.child(at: index) { visit(child, depth: 0) } }
        }
        return result
    }
    /// The title a page belongs to: the shallowest title on the page itself, otherwise the nearest
    /// earlier title, so every page of a multi-page recipe carries the recipe's name.
    func title(forPage page: Int) -> String? { Self.title(forPage: page, in: titles) }
    static func title(forPage page: Int, in titles: [Title]) -> String? {
        if let own = titles.filter({ $0.page == page }).min(by: { $0.depth < $1.depth }) { return own.label }
        return titles.last { $0.page < page }?.label
    }
    func search() {
        searches.advance()
        document?.cancelFindString(); results = []; current = nil; view.highlightedSelections = []; view.clearSelection()
        guard findActive, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; resumePage = nil; return }
        searching = true
        document?.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }
    nonisolated func didMatchString(_ instance: PDFSelection) {
        let generation = searches.value
        Task { @MainActor in
            // Old document callbacks and queries must never appear after replacement.
            guard self.searches.value == generation,
                  !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let document = self.document,
                  instance.pages.allSatisfy({ $0.document === document }),
                  instance.string?.range(of: self.query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return }
            instance.color = Self.matchColor
            self.results.append(instance)
            if self.current == nil { self.view.highlightedSelections = self.results }
            else if let highlighted = self.view.highlightedSelections { self.view.highlightedSelections = highlighted + [instance] }
            // Typing jumps to the first match straight away, like find in a browser.
            if self.current == nil {
                if let resume = self.resumePage {
                    if let page = instance.pages.first, document.index(for: page) >= resume { self.resumePage = nil; self.show(self.results.count - 1) }
                } else { self.show(0) }
            }
        }
    }
    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        let generation = searches.value
        Task { @MainActor in
            guard self.searches.value == generation, notification.object as? PDFDocument === self.document else { return }
            self.searching = false
            if self.current == nil, self.resumePage != nil { self.resumePage = nil; self.show(0) }
        }
    }
    func go(to index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        // Shown right away when the view is off screen, and kept if a layout is still pending.
        self.page = index
        let view = self.view
        view.navigate { if view.document === document { view.go(to: page) } }
    }
    func next() { step(1) }
    func previous() { step(-1) }
    /// Moves through the matches, wrapping around at either end.
    private func step(_ offset: Int) {
        guard !results.isEmpty else { return }
        guard let current else { show(offset > 0 ? 0 : results.count - 1); return }
        show((current + offset + results.count) % results.count)
    }
    private func show(_ index: Int) {
        guard results.indices.contains(index), let document, results[index].pages.allSatisfy({ $0.document === document }) else { return }
        current = index
        // The current match stands out from the other highlights. PDFView only redraws highlights it
        // has not seen, so the current one is drawn from its own copy.
        let highlight = (results[index].copy() as? PDFSelection) ?? results[index]
        highlight.color = Self.currentMatchColor
        view.highlightedSelections = nil
        view.highlightedSelections = results.enumerated().filter { $0.offset != index }.map(\.element) + [highlight]
        let selection = results[index], view = self.view
        view.navigate { [weak self] in
            guard view.document === document else { return }
            view.go(to: selection)
            self?.center(selection)
        }
    }
    /// Top edge of the find bar in window coordinates while it is shown. The bar and the keyboard
    /// below it cover the bottom of the page.
    @ObservationIgnored var findBarTop: CGFloat?
    /// `go(to:)` only scrolls a match to the edge of the view, where the navigation bar or the find
    /// bar can hide it. This moves the match to the middle of the area that is actually visible.
    private func center(_ selection: PDFSelection) {
        guard let page = selection.pages.first, let scrollView = Self.scrollView(in: view) else { return }
        view.layoutIfNeeded()
        let match = scrollView.convert(view.convert(selection.bounds(for: page), from: page), from: view)
        let inset = scrollView.adjustedContentInset
        let size = scrollView.bounds.size
        var top = max(inset.top, view.safeAreaInsets.top), bottom = size.height - max(inset.bottom, view.safeAreaInsets.bottom)
        if let findBarTop { bottom = min(bottom, scrollView.convert(CGPoint(x: 0, y: findBarTop), from: nil).y - scrollView.bounds.minY) }
        if bottom - top < 44 { top = 0; bottom = size.height }
        var offset = scrollView.contentOffset
        offset.y += match.midY - (scrollView.bounds.minY + (top + bottom) / 2)
        offset.y = min(max(offset.y, -inset.top), max(-inset.top, scrollView.contentSize.height - size.height + inset.bottom))
        // When zoomed in, keep the match horizontally on screen too.
        let left = scrollView.bounds.minX + inset.left, right = scrollView.bounds.maxX - inset.right
        if match.minX < left || match.maxX > right {
            offset.x += match.midX - (left + right) / 2
            offset.x = min(max(offset.x, -inset.left), max(-inset.left, scrollView.contentSize.width - size.width + inset.right))
        }
        scrollView.setContentOffset(offset, animated: false)
    }
    private static func scrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = scrollView(in: subview) { return nested }
        }
        return nil
    }
    private static let matchColor = UIColor.systemYellow.withAlphaComponent(0.35)
    private static let currentMatchColor = UIColor.systemOrange.withAlphaComponent(0.75)
    /// The page of the current match, zero-based.
    var currentMatchPage: Int? {
        guard let current, results.indices.contains(current), let page = results[current].pages.first, let document else { return nil }
        return document.index(for: page)
    }
    /// Hides the highlights but keeps the term, so reopening find picks up where it left off.
    func endFind() {
        searches.advance()
        findActive = false; resumePage = nil
        document?.cancelFindString(); results = []; current = nil; searching = false
        view.highlightedSelections = []; view.clearSelection()
    }
}
