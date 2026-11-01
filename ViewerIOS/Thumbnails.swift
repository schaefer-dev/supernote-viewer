import Observation
import PDFKit
import UIKit

/// First-page thumbnails of saved renderings, generated off the main actor on demand.
/// Documents that were never opened or synced have no thumbnail and show their kind's symbol.
@Observable @MainActor final class ThumbnailStore {
    private var images: [String: UIImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let cache: RenderedPDFCache
    static let size = CGSize(width: 96, height: 128)

    init(cache: RenderedPDFCache) { self.cache = cache }

    func thumbnail(account: String?, fileID: String) -> UIImage? {
        guard let account else { return nil }
        let key = Self.key(account, fileID)
        if let image = images[key] { return image }
        if requested.insert(key).inserted {
            let cache = self.cache
            Task {
                let image = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let latest = cache.latestRendering(accountID: account, fileID: fileID),
                          let page = PDFDocument(url: latest.url)?.page(at: 0) else { return nil }
                    return page.thumbnail(of: Self.size, for: .mediaBox)
                }.value
                if let image { images[key] = image }
            }
        }
        return nil
    }

    /// Forgets a thumbnail after a newer rendering is saved.
    func invalidate(account: String, fileID: String) {
        let key = Self.key(account, fileID)
        requested.remove(key); images[key] = nil
    }
    func removeAll() { requested.removeAll(); images.removeAll() }

    private nonisolated static func key(_ account: String, _ fileID: String) -> String { account + "\u{1F}" + fileID }
}

/// Page thumbnails for the reader's page grid. Pages render off the main actor from a private copy
/// of the displayed PDF, so scrolling the grid never touches the document the reader is showing.
/// Each grid cell asks for its own page, so no view has to observe a shared image store.
actor PageThumbnailRenderer {
    static let shared = PageThumbnailRenderer()
    /// Large enough to read handwriting in a two-column grid on iPhone.
    static let size = CGSize(width: 420, height: 560)
    private var url: URL?
    private var document: PDFDocument?
    private let images: NSCache<NSNumber, UIImage> = { let cache = NSCache<NSNumber, UIImage>(); cache.countLimit = 60; return cache }()

    /// Starts over when the reader shows a different file, such as the recognized version of a preview.
    func image(_ index: Int, in url: URL) -> UIImage? {
        if url != self.url { self.url = url; document = PDFDocument(url: url); images.removeAllObjects() }
        if let image = images.object(forKey: index as NSNumber) { return image }
        guard let image = document?.page(at: index)?.thumbnail(of: Self.size, for: .mediaBox) else { return nil }
        images.setObject(image, forKey: index as NSNumber)
        return image
    }
}
