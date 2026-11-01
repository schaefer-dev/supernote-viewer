import Foundation
import Observation

struct RemoteEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    var revision: String? = nil
    var size: UInt64 = 0
    var parentPath: String { (path as NSString).deletingLastPathComponent == "/" ? "" : (path as NSString).deletingLastPathComponent }
    var isAnnotation: Bool { name.lowercased().hasSuffix(".pdf.mark") }
    var isSupported: Bool { isFolder || ["note", "pdf"].contains((name as NSString).pathExtension.lowercased()) || isAnnotation }
}

struct FolderPage: Sendable {
    let entries: [RemoteEntry]
    let cursor: String
    let hasMore: Bool
}

@MainActor protocol DropboxService {
    func list(path: String, cursor: String?) async throws -> FolderPage
    func metadata(id: String) async throws -> RemoteEntry
    func download(_ entry: RemoteEntry, to: URL, progress: @escaping (Double) -> Void) async throws -> RemoteEntry
}

enum ReaderError: LocalizedError {
    case message(String), missingCompanion, reconnect, rateLimited(Date)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .missingCompanion: return "The original PDF is missing from this folder. Retry after syncing it, or choose Open Annotations Only."
        case .reconnect: return "Dropbox authorization is unavailable. Connect or reconnect your account."
        case .rateLimited(let date): return "Dropbox is busy. Retry after \(date.formatted(date: .omitted, time: .standard))."
        }
    }
}

@MainActor func allEntries(service: any DropboxService, path: String) async throws -> [RemoteEntry] {
    var entries: [RemoteEntry] = []
    var cursor: String?
    var seen: Set<String> = []
    repeat {
        try Task.checkCancellation()
        let page = try await service.list(path: path, cursor: cursor)
        entries += page.entries
        if !page.hasMore { return entries }
        guard seen.insert(page.cursor).inserted else { throw ReaderError.message("Dropbox returned a repeated folder cursor. Refresh this folder.") }
        cursor = page.cursor
    } while true
}

struct LibraryItem: Identifiable, Hashable {
    let entry: RemoteEntry
    let original: RemoteEntry?
    var id: String { entry.id }
    var name: String { entry.isAnnotation ? String(entry.name.dropLast(5)) : entry.name }
    var icon: String { entry.isFolder ? "folder" : entry.isAnnotation ? "doc.richtext" : entry.name.lowercased().hasSuffix(".note") ? "book.closed" : "doc" }
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
    enum Source: String, Codable { case dropbox, example, imported }
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
    var records: [RecentDocument]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = (defaults.data(forKey: "mobile.recents").flatMap { try? JSONDecoder().decode([RecentDocument].self, from: $0) }) ?? []
    }
    func page(for reference: DocumentReference) -> Int { records.first { $0.id == reference.id }?.page ?? 0 }
    func save(_ reference: DocumentReference, page: Int) {
        guard reference.source != .imported else { return }
        records.removeAll { $0.id == reference.id }
        records.insert(.init(reference: reference, page: max(0, page), opened: Date()), at: 0)
        records = Array(records.prefix(30))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "mobile.recents") }
    }
    func root(account: String) -> RemoteEntry? {
        defaults.data(forKey: "mobile.root.\(account)").flatMap { try? JSONDecoder().decode(RemoteEntry.self, from: $0) }
    }
    func setRoot(_ folder: RemoteEntry?, account: String) {
        defaults.set(folder.flatMap { try? JSONEncoder().encode($0) }, forKey: "mobile.root.\(account)")
    }
}
