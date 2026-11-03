import CryptoKit
import Foundation
import SupernoteKit

/// Identifies one finished rendering of a Dropbox document.
///
/// Every input that changes the output is part of the key: the account and stable file ID,
/// the source revision, the companion PDF's identity and revision (or an explicit
/// annotations-only marker), and the shared renderer version. Paths and modification
/// times are deliberately excluded because they are not revision identities.
struct RenderCacheKey: Hashable, Sendable {
    enum Companion: Hashable, Sendable {
        /// The source is a notebook or ordinary PDF and has no companion.
        case none
        /// The user explicitly chose to open annotations without their original PDF.
        case annotationsOnly
        case original(id: String, revision: String)
    }
    let accountID: String
    let fileID: String
    let sourceRevision: String
    let companion: Companion
    var rendererVersion = PDFRenderer.version
    /// False for a readable preview without recognized handwriting; sync saves these
    /// first so a large library becomes readable offline quickly.
    var recognized = true

    var preview: RenderCacheKey { var key = self; key.recognized = false; return key }
    var searchable: RenderCacheKey { var key = self; key.recognized = true; return key }

    var fileName: String {
        let companionPart: String
        switch companion {
        case .none: companionPart = "none"
        case .annotationsOnly: companionPart = "annotations-only"
        case .original(let id, let revision): companionPart = "original:\(id):\(revision)"
        }
        // Searchable renderings keep the original naming, so earlier saves stay valid.
        let identity = (["v1", sourceRevision, companionPart, String(rendererVersion)] + (recognized ? [] : ["preview"]))
            .joined(separator: "\u{1F}")
        return filePrefix + Self.digest(identity) + ".pdf"
    }
    /// Shared by every saved rendering of one Dropbox file, whatever its revision, so the
    /// newest one can be found offline from the file name alone.
    var filePrefix: String { Self.digest(fileID) + "-" }
    var accountFolder: String { Self.digest(accountID) }
    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps the newest completed, searchable PDF of each Dropbox document on the device.
///
/// An unchanged revision reopens without downloading or rendering, and the newest rendering
/// remains readable offline. Renderings live in Application Support (excluded from backup),
/// so iOS does not purge them; each document keeps only its newest rendering, and the user
/// can remove everything from Settings.
final class RenderedPDFCache: Sendable {
    let root: URL

    static let shared = RenderedPDFCache(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupernoteRenderings", isDirectory: true))

    /// Builds 11–14 kept renderings in Caches, where iOS may purge them.
    static let legacyRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SupernoteRenderedPDFs", isDirectory: true)

    init(root: URL) {
        self.root = root
    }

    /// Moves renderings saved by earlier builds into durable storage, once.
    func adoptLegacyRenderings(from legacy: URL = RenderedPDFCache.legacyRoot) {
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: legacy)
        } else {
            try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: legacy, to: root)) == nil { try? FileManager.default.removeItem(at: legacy) }
        }
        excludeFromBackup()
    }

    private func url(for key: RenderCacheKey) -> URL {
        root.appendingPathComponent(key.accountFolder, isDirectory: true).appendingPathComponent(key.fileName)
    }

    func contains(_ key: RenderCacheKey) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    enum Availability: Sendable { case none, preview, searchable }
    /// What is saved for exactly these revisions.
    func availability(_ key: RenderCacheKey) -> Availability {
        if contains(key.searchable) { return .searchable }
        return contains(key.preview) ? .preview : .none
    }

    /// Places the saved PDF for `key` into `directory` and returns its URL, or nil on a miss.
    /// The workspace receives its own link so later removal cannot affect a displayed file.
    func materialize(_ key: RenderCacheKey, into directory: URL) -> URL? {
        let cached = url(for: key)
        guard FileManager.default.fileExists(atPath: cached.path) else { return nil }
        let destination = directory.appendingPathComponent("cached-\(UUID().uuidString).pdf")
        return (try? Self.linkOrCopy(cached, to: destination)) == nil ? nil : destination
    }

    /// Publishes a completed PDF atomically and removes superseded renderings of the same
    /// document. Failures are ignored: the document can always be rendered again.
    func store(_ file: URL, for key: RenderCacheKey) {
        let destination = url(for: key)
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            excludeFromBackup()
            try Self.linkOrCopy(file, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return
        }
        let superseded = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(key.filePrefix) && $0.lastPathComponent != key.fileName }
        for file in superseded { try? FileManager.default.removeItem(at: file) }
    }

    /// Places the newest saved rendering of a file into `directory`, regardless of revision.
    /// Only for use when Dropbox cannot confirm the current revision; the result may be outdated.
    func materializeLatest(accountID: String, fileID: String, into directory: URL) -> (url: URL, savedAt: Date)? {
        guard let newest = latestRendering(accountID: accountID, fileID: fileID) else { return nil }
        let destination = directory.appendingPathComponent("cached-\(UUID().uuidString).pdf")
        guard (try? Self.linkOrCopy(newest.url, to: destination)) != nil else { return nil }
        return (destination, newest.savedAt)
    }

    /// The newest saved rendering of a file in place, for read-only uses such as thumbnails.
    func latestRendering(accountID: String, fileID: String) -> (url: URL, savedAt: Date)? {
        let probe = RenderCacheKey(accountID: accountID, fileID: fileID, sourceRevision: "", companion: .none)
        let folder = root.appendingPathComponent(probe.accountFolder, isDirectory: true)
        // Creation time is when the rendering was produced.
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "pdf" && $0.lastPathComponent.hasPrefix(probe.filePrefix) }
            .map { (url: $0, created: (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast) }
        return candidates.max(by: { $0.created < $1.created }).map { ($0.url, $0.created) }
    }

    /// Number of saved documents and their total size, for Settings.
    func usage() -> (documents: Int, bytes: UInt64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return (0, 0) }
        var count = 0, bytes: UInt64 = 0
        for case let file as URL in enumerator where file.pathExtension == "pdf" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            count += 1; bytes += UInt64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }

    /// Removes every saved rendering for an account, e.g. when it disconnects.
    func removeAll(accountID: String) {
        let folder = root.appendingPathComponent(RenderCacheKey(accountID: accountID, fileID: "", sourceRevision: "", companion: .none).accountFolder)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes every saved rendering on the device.
    func removeEverything() { try? FileManager.default.removeItem(at: root) }

    private func excludeFromBackup() {
        var url = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func linkOrCopy(_ source: URL, to destination: URL) throws {
        do { try FileManager.default.linkItem(at: source, to: destination) }
        catch { try FileManager.default.copyItem(at: source, to: destination) }
    }
}
