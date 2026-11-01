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

    var fileName: String {
        let companionPart: String
        switch companion {
        case .none: companionPart = "none"
        case .annotationsOnly: companionPart = "annotations-only"
        case .original(let id, let revision): companionPart = "original:\(id):\(revision)"
        }
        let identity = ["v1", sourceRevision, companionPart, String(rendererVersion)].joined(separator: "\u{1F}")
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

/// Stores completed, searchable PDFs for Dropbox documents so an unchanged revision reopens
/// without downloading or rendering again. This is a regenerable cache, not offline storage:
/// iOS may purge it, and opening still checks Dropbox metadata first.
final class RenderedPDFCache: Sendable {
    let root: URL
    let byteLimit: UInt64

    static let shared = RenderedPDFCache(
        root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupernoteRenderedPDFs", isDirectory: true),
        byteLimit: 1 << 30)

    init(root: URL, byteLimit: UInt64) {
        self.root = root
        self.byteLimit = byteLimit
    }

    private func url(for key: RenderCacheKey) -> URL {
        root.appendingPathComponent(key.accountFolder, isDirectory: true).appendingPathComponent(key.fileName)
    }

    /// Places the cached PDF for `key` into `directory` and returns its URL, or nil on a miss.
    /// The workspace receives its own link so pruning cannot remove a displayed file.
    func materialize(_ key: RenderCacheKey, into directory: URL) -> URL? {
        let cached = url(for: key)
        guard FileManager.default.fileExists(atPath: cached.path) else { return nil }
        let destination = directory.appendingPathComponent("cached-\(UUID().uuidString).pdf")
        do {
            try Self.linkOrCopy(cached, to: destination)
            // The modification date doubles as the last-opened time for pruning.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return destination
        } catch {
            return nil
        }
    }

    /// Publishes a completed PDF atomically. Failures are ignored: the cache is an optimization.
    func store(_ file: URL, for key: RenderCacheKey) {
        let destination = url(for: key)
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        prune()
    }

    /// Places the newest saved rendering of a file into `directory`, regardless of revision.
    /// Only for use when Dropbox cannot confirm the current revision; the result may be outdated.
    func materializeLatest(accountID: String, fileID: String, into directory: URL) -> (url: URL, savedAt: Date)? {
        let probe = RenderCacheKey(accountID: accountID, fileID: fileID, sourceRevision: "", companion: .none)
        let folder = root.appendingPathComponent(probe.accountFolder, isDirectory: true)
        // Creation time is when the rendering was produced; modification time tracks last use.
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let candidates = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "pdf" && $0.lastPathComponent.hasPrefix(probe.filePrefix) }
            .map { (url: $0, created: (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast) }
        guard let newest = candidates.max(by: { $0.created < $1.created }) else { return nil }
        let destination = directory.appendingPathComponent("cached-\(UUID().uuidString).pdf")
        guard (try? Self.linkOrCopy(newest.url, to: destination)) != nil else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newest.url.path)
        return (destination, newest.created)
    }

    /// Removes every cached rendering for an account, e.g. when it disconnects.
    func removeAll(accountID: String) {
        let folder = root.appendingPathComponent(RenderCacheKey(accountID: accountID, fileID: "", sourceRevision: "", companion: .none).accountFolder)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes the least recently opened renderings until the cache fits its byte limit.
    func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: UInt64, date: Date)] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  file.pathExtension == "pdf", !file.lastPathComponent.hasPrefix(".staging-") else { continue }
            files.append((file, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > byteLimit {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    private static func linkOrCopy(_ source: URL, to destination: URL) throws {
        do { try FileManager.default.linkItem(at: source, to: destination) }
        catch { try FileManager.default.copyItem(at: source, to: destination) }
    }
}
