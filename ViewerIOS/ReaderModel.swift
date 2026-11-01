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

@Observable @MainActor final class ReaderModel: NSObject, PDFDocumentDelegate {
    let view = PDFView()
    @ObservationIgnored nonisolated private let searches = SearchGeneration()
    var query = ""
    var results: [PDFSelection] = []
    var searching = false
    var document: PDFDocument?
    var titles: [Title] = []
    var page = 0
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    var pageChanged: ((Int) -> Void)?
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
                guard let self, let document = self.document, let current = self.view.currentPage else { return }
                self.page = document.index(for: current)
                self.pageChanged?(self.page)
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func reset() {
        searches.advance()
        document?.cancelFindString(); document?.delegate = nil
        document = nil; view.document = nil; workspace = nil; results = []; titles = []; page = 0; query = ""; searching = false
    }
    func replace(_ document: PDFDocument, page requestedPage: Int, workspace: Workspace? = nil) {
        guard document !== self.document else { return }
        searches.advance()
        let replacing = self.document != nil
        let destination = view.currentDestination
        let zoom = view.scaleFactor / max(view.scaleFactorForSizeToFit, 0.01)
        self.document?.cancelFindString()
        self.document?.delegate = nil
        results = []; view.highlightedSelections = []; view.clearSelection()
        self.document = document; document.delegate = self
        view.document = document
        self.workspace = workspace
        page = min(max(0, requestedPage), max(0, document.pageCount - 1))
        if let newPage = document.page(at: page) {
            if replacing, let destination { view.go(to: PDFDestination(page: newPage, at: destination.point)) }
            else { view.go(to: newPage) }
        }
        if replacing { view.scaleFactor = max(view.minScaleFactor, min(view.maxScaleFactor, view.scaleFactorForSizeToFit * zoom)) }
        titles = Self.titles(in: document)
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
    func search() {
        searches.advance()
        document?.cancelFindString(); results = []; view.highlightedSelections = []; view.clearSelection()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
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
            self.results.append(instance)
        }
    }
    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        let generation = searches.value
        Task { @MainActor in
            if self.searches.value == generation, notification.object as? PDFDocument === self.document { self.searching = false }
        }
    }
    func go(to page: Int) { if let page = document?.page(at: page) { view.go(to: page) } }
    func select(_ selection: PDFSelection) {
        guard selection.pages.allSatisfy({ $0.document === document }) else { return }
        selection.color = .systemYellow
        view.setCurrentSelection(selection, animate: true); view.go(to: selection)
    }
}
