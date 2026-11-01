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
