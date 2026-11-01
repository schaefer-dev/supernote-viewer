import Foundation
import Observation
import UIKit

struct RemoteEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    var revision: String? = nil
    var size: UInt64 = 0
    /// When Dropbox last received a change; nil for folders and older stored entries.
    var modified: Date? = nil
    var parentPath: String { (path as NSString).deletingLastPathComponent == "/" ? "" : (path as NSString).deletingLastPathComponent }
    var isAnnotation: Bool { name.lowercased().hasSuffix(".pdf.mark") }
    var isSupported: Bool { isFolder || ["note", "pdf"].contains((name as NSString).pathExtension.lowercased()) || isAnnotation }
}

/// "iPhone" or "iPad", for text that refers to this device.
@MainActor var deviceName: String { UIDevice.current.model }

/// The name people expect to read: without `.note`, `.pdf` or `.pdf.mark`.
func displayName(_ fileName: String) -> String {
    let lower = fileName.lowercased()
    for suffix in [".pdf.mark", ".note", ".pdf", ".mark"] where lower.hasSuffix(suffix) && lower.count > suffix.count {
        return String(fileName.dropLast(suffix.count))
    }
    return fileName
}

enum DocumentKind {
    case folder, notebook, annotatedPDF, pdf
    init(fileName: String, isFolder: Bool = false) {
        let lower = fileName.lowercased()
        if isFolder { self = .folder }
        else if lower.hasSuffix(".mark") { self = .annotatedPDF }
        else if lower.hasSuffix(".note") { self = .notebook }
        else { self = .pdf }
    }
    var label: String {
        switch self { case .folder: "Folder"; case .notebook: "Notebook"; case .annotatedPDF: "Annotated PDF"; case .pdf: "PDF" }
    }
    var symbol: String {
        switch self { case .folder: "folder.fill"; case .notebook: "book.closed"; case .annotatedPDF: "doc.richtext"; case .pdf: "doc" }
    }
}

/// "Today, 14:05", "Yesterday", or a short date: compact enough for a list row.
func shortModified(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

struct FolderPage: Sendable {
    let entries: [RemoteEntry]
    let cursor: String
    let hasMore: Bool
}

@MainActor protocol DropboxService {
    func list(path: String, cursor: String?, recursive: Bool) async throws -> FolderPage
    func metadata(id: String) async throws -> RemoteEntry
    func download(_ entry: RemoteEntry, to: URL, progress: @escaping (Double) -> Void) async throws -> RemoteEntry
}

enum ReaderError: LocalizedError {
    /// Dropbox could not be reached; a saved rendering may still be shown.
    case message(String), offline(String), missingCompanion, reconnect, rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .message(let message), .offline(let message): return message
        case .missingCompanion: return "The original PDF is missing from this folder. Retry after syncing it, or choose Open Annotations Only."
        case .reconnect: return "Dropbox authorization is unavailable. Connect or reconnect your account."
        case .rateLimited(let date): return "Dropbox is busy. Retry after \(date.formatted(date: .omitted, time: .standard))."
        }
    }
}

@MainActor func allEntries(service: any DropboxService, path: String, recursive: Bool = false) async throws -> [RemoteEntry] {
    var entries: [RemoteEntry] = []
    var cursor: String?
    var seen: Set<String> = []
    repeat {
        try Task.checkCancellation()
        let page = try await service.list(path: path, cursor: cursor, recursive: recursive)
        entries += page.entries
        if !page.hasMore { return entries }
        guard seen.insert(page.cursor).inserted else { throw ReaderError.message("Dropbox returned a repeated folder cursor. Refresh this folder.") }
        cursor = page.cursor
    } while true
}

/// Downloads one specific revision into `directory` and publishes it under `name` only after
/// the returned ID, revision and byte count match the requested metadata.
@MainActor func downloadSnapshot(_ entry: RemoteEntry, service: any DropboxService, into directory: URL, name: String,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
    let partial = directory.appendingPathComponent(name + ".partial")
    let returned = try await service.download(entry, to: partial, progress: progress)
    try Task.checkCancellation()
    let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
    guard returned.id == entry.id, returned.revision == entry.revision, size?.uint64Value == entry.size else {
        throw ReaderError.message("The downloaded snapshot did not match Dropbox metadata. Retry opening the document.")
    }
    let complete = directory.appendingPathComponent(name)
    try FileManager.default.moveItem(at: partial, to: complete)
    return complete
}

struct LibraryItem: Identifiable, Hashable {
    let entry: RemoteEntry
    let original: RemoteEntry?
    var id: String { entry.id }
    var name: String { entry.isFolder ? entry.name : displayName(entry.name) }
    var kind: DocumentKind { DocumentKind(fileName: entry.name, isFolder: entry.isFolder) }
    /// Kind, last change and size, e.g. "Notebook · Yesterday · 2.4 MB".
    var detail: String {
        var parts = [kind.label]
        if let modified = [entry.modified, original?.modified].compactMap({ $0 }).max() { parts.append(shortModified(modified)) }
        let bytes = entry.size + (original?.size ?? 0)
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
    /// Folders that look like the Supernote sync folder, offered first when choosing the library folder.
    static func supernoteFolders(in items: [Self]) -> [Self] {
        items.filter { $0.entry.isFolder && $0.entry.name.localizedCaseInsensitiveContains("supernote") }
    }
    static func group(_ entries: [RemoteEntry]) -> [Self] {
        let annotations = entries.filter { $0.isAnnotation }
        let originals = Set(annotations.compactMap { mark in entries.first { !$0.isFolder && $0.parentPath == mark.parentPath && $0.name.lowercased() == String(mark.name.dropLast(5)).lowercased() }?.id })
        return entries.filter { $0.isSupported && !originals.contains($0.id) }.map { entry in
            Self(entry: entry, original: entry.isAnnotation ? entries.first { !$0.isFolder && $0.parentPath == entry.parentPath && $0.name.lowercased() == String(entry.name.dropLast(5)).lowercased() } : nil)
        }.sorted { a, b in
            if a.entry.isFolder != b.entry.isFolder { return a.entry.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

@Observable @MainActor final class FolderBrowserModel {
    var items: [LibraryItem] = []
    /// Items whose current revision is saved on the device.
    var available: Set<String> = []
    func refreshAvailability(account: String?, cache: RenderedPDFCache) async {
        guard let account else { available = []; return }
        let keyed = items.compactMap { item in
            DocumentOpenCoordinator.cacheKey(account: account, source: item.entry, original: item.original, annotationsOnly: false).map { (item.id, $0) }
        }
        available = await Task.detached(priority: .utility) { Set(keyed.filter { cache.availability($0.1) != .none }.map(\.0)) }.value
    }
    var loading = false
    var error: String?
    private var generation = UUID()
    func refresh(service: any DropboxService, folder: RemoteEntry?) async {
        let operation = UUID(); generation = operation
        loading = true; error = nil
        do {
            // IDs survive folder moves and renames.
            let entries = try await allEntries(service: service, path: folder?.id ?? "")
            guard operation == generation else { return }
            items = LibraryItem.group(entries)
        } catch {
            guard operation == generation else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if operation == generation { loading = false }
    }
}

struct DocumentReference: Codable, Hashable, Identifiable {
    /// `fixture` is a repository file opened by UI tests in debug builds. Its raw value is the one
    /// former bundled examples used, so their stored recents decode and are then dropped.
    enum Source: String, Codable { case dropbox, fixture = "example", imported }
    let source: Source
    let accountID: String?
    let fileID: String
    let name: String
    var path: String?
    var id: String { "\(source.rawValue):\(accountID ?? "local"):\(fileID)" }
    static func remote(_ entry: RemoteEntry, account: String) -> Self {
        Self(source: .dropbox, accountID: account, fileID: entry.id, name: entry.name, path: entry.path)
    }
}
struct RecentDocument: Codable, Identifiable {
    let reference: DocumentReference
    var page: Int
    var opened: Date
    var id: String { reference.id }
}

@Observable @MainActor final class RecentDocumentsStore {
    private let defaults: UserDefaults
    static let limit = 100
    var records: [RecentDocument]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.data(forKey: "mobile.recents").flatMap { try? JSONDecoder().decode([RecentDocument].self, from: $0) }) ?? []
        records = stored.filter { $0.reference.source == .dropbox }
    }
    func page(for reference: DocumentReference) -> Int { records.first { $0.id == reference.id }?.page ?? 0 }
    func save(_ reference: DocumentReference, page: Int) {
        guard reference.source != .imported else { return }
        records.removeAll { $0.id == reference.id }
        records.insert(.init(reference: reference, page: max(0, page), opened: Date()), at: 0)
        records = Array(records.prefix(Self.limit))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "mobile.recents") }
    }
    func remove(_ recent: RecentDocument) {
        records.removeAll { $0.id == recent.id }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "mobile.recents") }
    }
    /// Forgets an account's recent documents and chosen library folder.
    func removeAll(account: String) {
        records.removeAll { $0.reference.accountID == account }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "mobile.recents") }
        defaults.removeObject(forKey: "mobile.root.\(account)")
        rootRevision += 1
    }
    /// Advances when a library folder is chosen or forgotten, so views reading `root` refresh.
    private(set) var rootRevision = 0
    func root(account: String) -> RemoteEntry? {
        _ = rootRevision
        return defaults.data(forKey: "mobile.root.\(account)").flatMap { try? JSONDecoder().decode(RemoteEntry.self, from: $0) }
    }
    func setRoot(_ folder: RemoteEntry?, account: String) {
        defaults.set(folder.flatMap { try? JSONEncoder().encode($0) }, forKey: "mobile.root.\(account)")
        rootRevision += 1
    }
}
