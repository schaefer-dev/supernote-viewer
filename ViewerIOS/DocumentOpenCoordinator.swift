import Foundation
import Observation
import PDFKit
import SupernoteKit

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

final class Workspace: @unchecked Sendable {
    let url: URL
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("SupernoteMobileSessions", isDirectory: true)
    static func cleanAbandoned() { try? FileManager.default.removeItem(at: root) }
    init() throws {
        url = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
struct LocalInputs: Sendable {
    let source: URL
    let companion: URL?
    let workspace: Workspace
}
struct OpeningMetrics {
    var started = Date()
    var downloadSeconds: TimeInterval?
    var previewSeconds: TimeInterval?
    var recognitionSeconds: TimeInterval?
    var inputBytes: UInt64 = 0
    var openedFromCache = false
    /// Set when Dropbox was unreachable and an older saved rendering is shown.
    var offlineSavedAt: Date?
}
struct DisplayedDocument {
    let document: PDFDocument
    let url: URL
    let workspace: Workspace
}

protocol MobileRendering: Sendable {
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping @Sendable (String) -> Void) async throws
}
struct EngineRenderer: MobileRendering {
    private static let queue = DispatchQueue(label: "SupernoteMobileRenderer", qos: .userInitiated)
    func render(_ inputs: LocalInputs, to output: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    if token.isCancelled { throw CancellationError() }
                    let diagnostics = RecognitionDiagnostics()
                    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SupernoteOCR")
                    try PDFRenderer.write(contentsOf: inputs.source, companionPDFURL: inputs.companion, to: output,
                        options: RenderOptions(textLayer: recognize, ocrCacheDirectory: cache,
                            progress: { done, total in progress("Recognizing handwriting… \(done)/\(total)") },
                            pageProgress: { done, total in if !recognize { progress("Rendering pages… \(done)/\(total)") } },
                            maximumConcurrentPageWork: 2, isCancelled: { token.isCancelled },
                            recognitionError: { _, _ in diagnostics.recordFailure() }))
                    if diagnostics.failed { throw ReaderError.message("Some handwriting could not be recognized. The readable preview is retained. Retry recognition when active.") }
                    continuation.resume()
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
private final class RecognitionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = false
    var failed: Bool { lock.withLock { failures } }
    func recordFailure() { lock.withLock { failures = true } }
}

@Observable @MainActor final class DocumentOpenCoordinator {
    var reference: DocumentReference?
    var displayed: DisplayedDocument?
    var status: String?
    var error: String?
    var warning: String?
    var missingCompanion = false
    var recognizing = false
    var metrics = OpeningMetrics()
    var page = 0
    var generation = UUID()
    private var task: Task<Void, Never>?
    private var token = CancellationToken()
    private var inputs: LocalInputs?
    /// Identifies the finished rendering of the current Dropbox open; nil for local documents.
    private var cacheKey: RenderCacheKey?
    private let renderer: any MobileRendering
    private let recents: RecentDocumentsStore
    private let cache: RenderedPDFCache?
    init(recents: RecentDocumentsStore, renderer: any MobileRendering = EngineRenderer(), cache: RenderedPDFCache? = nil) {
        self.recents = recents; self.renderer = renderer; self.cache = cache
    }
    func cancel() {
        token.cancel(); task?.cancel(); generation = UUID(); status = nil; recognizing = false
    }
    private func begin(_ reference: DocumentReference) -> UUID {
        cancel(); token = CancellationToken()
        savePosition()
        let sameDocument = self.reference?.id == reference.id
        self.reference = reference; error = nil; warning = nil; missingCompanion = false
        if !sameDocument { displayed = nil }
        inputs = nil; cacheKey = nil
        page = recents.page(for: reference)
        metrics = OpeningMetrics()
        status = "Preparing document…"
        return generation
    }
    func openRemote(_ reference: DocumentReference, service: any DropboxService, annotationsOnly: Bool = false) {
        let operation = begin(reference)
        task = Task {
            do {
                let workspace = try Workspace()
                let source = try await service.metadata(id: reference.fileID)
                try check(operation)
                guard source.id == reference.fileID else { throw ReaderError.message("Dropbox returned a different document. Refresh the folder.") }
                self.reference = .remote(source, account: reference.accountID ?? "")
                var original: RemoteEntry?
                if source.isAnnotation && !annotationsOnly {
                    guard !source.path.isEmpty else { throw ReaderError.message("Dropbox did not return the annotations' parent folder. Refresh and retry.") }
                    let entries = try await allEntries(service: service, path: source.parentPath)
                    guard let candidate = entries.first(where: { !$0.isFolder && $0.parentPath == source.parentPath && $0.name.lowercased() == String(source.name.dropLast(5)).lowercased() }) else { throw ReaderError.missingCompanion }
                    let fresh = try await service.metadata(id: candidate.id)
                    guard fresh.id == candidate.id, fresh.parentPath == source.parentPath,
                          fresh.name.lowercased() == String(source.name.dropLast(5)).lowercased() else { throw ReaderError.missingCompanion }
                    original = fresh
                }
                try check(operation)
                if let key = Self.cacheKey(account: reference.accountID, source: source, original: original, annotationsOnly: annotationsOnly) {
                    cacheKey = key
                    if try await showCached(key, workspace: workspace, operation: operation) { return }
                }
                let companion = try await original.asyncMap { try await self.download($0, service: service, workspace: workspace, operation: operation, name: "original.pdf") }
                let url = try await download(source, service: service, workspace: workspace, operation: operation, name: "source." + (source.name as NSString).pathExtension)
                try check(operation)
                let local = LocalInputs(source: url, companion: companion, workspace: workspace)
                inputs = local
                metrics.downloadSeconds = Date().timeIntervalSince(metrics.started)
                metrics.inputBytes = source.size + (companion.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.uint64Value ?? 0)
                try await show(local, operation: operation)
            } catch {
                if case ReaderError.offline = error, (try? await showLatestCached(reference, operation: operation)) == true { return }
                fail(error, operation: operation)
            }
        }
    }
    /// Without a connection the current revision is unknown, so show the newest saved
    /// rendering and say so, rather than refusing to open the document.
    private func showLatestCached(_ reference: DocumentReference, operation: UUID) async throws -> Bool {
        guard let cache, let account = reference.accountID, !account.isEmpty else { return false }
        let workspace = try Workspace()
        let directory = workspace.url, fileID = reference.fileID
        guard let (url, savedAt) = await Task.detached(priority: .userInitiated, operation: {
            cache.materializeLatest(accountID: account, fileID: fileID, into: directory)
        }).value else { return false }
        guard operation == generation else { return false }
        do { try publish(url, local: LocalInputs(source: url, companion: nil, workspace: workspace), operation: operation) }
        catch { return false }
        cacheKey = nil
        metrics.openedFromCache = true; metrics.offlineSavedAt = savedAt
        status = nil
        warning = "Offline: showing the version saved \(savedAt.formatted(date: .abbreviated, time: .shortened)). It may be out of date. Reload when connected."
        return true
    }
    nonisolated static func cacheKey(account: String?, source: RemoteEntry, original: RemoteEntry?, annotationsOnly: Bool) -> RenderCacheKey? {
        guard let account, !account.isEmpty, let revision = source.revision else { return nil }
        let companion: RenderCacheKey.Companion
        if let original {
            guard let originalRevision = original.revision else { return nil }
            companion = .original(id: original.id, revision: originalRevision)
        } else if source.isAnnotation {
            guard annotationsOnly else { return nil }
            companion = .annotationsOnly
        } else { companion = .none }
        return RenderCacheKey(accountID: account, fileID: source.id, sourceRevision: revision, companion: companion)
    }
    /// Displays a finished rendering of exactly these revisions, if one is cached.
    private func showCached(_ key: RenderCacheKey, workspace: Workspace, operation: UUID) async throws -> Bool {
        guard let cache else { return false }
        let directory = workspace.url
        guard let url = await Task.detached(priority: .userInitiated, operation: { cache.materialize(key, into: directory) }).value else { return false }
        try check(operation)
        do {
            try publish(url, local: LocalInputs(source: url, companion: nil, workspace: workspace), operation: operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A damaged cache entry falls back to downloading and rendering again.
            try? FileManager.default.removeItem(at: url)
            return false
        }
        metrics.openedFromCache = true
        metrics.downloadSeconds = nil
        status = nil
        return true
    }
    /// Records a completed output in the cache without blocking the main actor.
    private func storeCompleted(_ url: URL, operation: UUID) {
        guard operation == generation, let cache, let key = cacheKey else { return }
        Task.detached(priority: .utility) { cache.store(url, for: key) }
    }
    private func download(_ entry: RemoteEntry, service: any DropboxService, workspace: Workspace, operation: UUID, name: String) async throws -> URL {
        let partial = workspace.url.appendingPathComponent(name + ".partial")
        let returned = try await service.download(entry, to: partial) { [weak self] fraction in
            Task { @MainActor in
                guard self?.generation == operation, self?.status != nil else { return }
                self?.status = "Downloading \(entry.name)… \(Int(fraction * 100))%"
            }
        }
        try check(operation)
        let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        guard returned.id == entry.id, returned.revision == entry.revision, size?.uint64Value == entry.size else {
            throw ReaderError.message("The downloaded snapshot did not match Dropbox metadata. Retry opening the document.")
        }
        let complete = workspace.url.appendingPathComponent(name)
        try FileManager.default.moveItem(at: partial, to: complete)
        return complete
    }
    func openLocal(_ reference: DocumentReference, source: URL, companion: URL? = nil, annotationsOnly: Bool = false) {
        let operation = begin(reference)
        task = Task {
            do {
                if source.pathExtension.lowercased() == "mark" && companion == nil && !annotationsOnly { throw ReaderError.missingCompanion }
                let workspace = try Workspace()
                let local = try await Task.detached(priority: .userInitiated) {
                    let copied = try Self.copyAuthorized(source, to: workspace.url.appendingPathComponent(source.lastPathComponent))
                    let original = try companion.map { try Self.copyAuthorized($0, to: workspace.url.appendingPathComponent("original.pdf")) }
                    return LocalInputs(source: copied, companion: original, workspace: workspace)
                }.value
                try check(operation)
                inputs = local
                try await show(local, operation: operation)
            } catch { fail(error, operation: operation) }
        }
    }
    nonisolated static func copyAuthorized(_ source: URL, to destination: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result { try FileManager.default.copyItem(at: url, to: destination) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        return destination
    }
    private func show(_ local: LocalInputs, operation: UUID) async throws {
        if local.source.pathExtension.lowercased() == "pdf" {
            try publish(local.source, local: local, operation: operation)
            storeCompleted(local.source, operation: operation)
            status = nil
            return
        }
        let previewStarted = Date()
        let preview = local.workspace.url.appendingPathComponent("preview-\(UUID().uuidString).pdf")
        try await renderer.render(local, to: preview, recognize: false, token: token, progress: progress(operation))
        try publish(preview, local: local, operation: operation)
        metrics.previewSeconds = Date().timeIntervalSince(previewStarted)
        await enhance(local, operation: operation)
    }
    private func enhance(_ local: LocalInputs, operation: UUID) async {
        let started = Date()
        recognizing = true; status = "Recognizing handwriting…"
        do {
            let searchable = local.workspace.url.appendingPathComponent("searchable-\(UUID().uuidString).pdf")
            try await renderer.render(local, to: searchable, recognize: true, token: token, progress: progress(operation))
            try publish(searchable, local: local, operation: operation)
            storeCompleted(searchable, operation: operation)
            metrics.recognitionSeconds = Date().timeIntervalSince(started)
            recognizing = false; status = nil; warning = nil
        } catch {
            guard generation == operation else { return }
            recognizing = false; status = nil
            if !token.isCancelled { warning = error.localizedDescription }
        }
    }
    private func progress(_ operation: UUID) -> @Sendable (String) -> Void {
        { [weak self] status in Task { @MainActor in if self?.generation == operation, self?.status != nil { self?.status = status } } }
    }
    private func publish(_ url: URL, local: LocalInputs, operation: UUID) throws {
        try check(operation)
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw ReaderError.message("This PDF is unreadable or password locked. Use an unlocked PDF and retry.")
        }
        displayed = .init(document: document, url: url, workspace: local.workspace)
        page = min(max(0, page), document.pageCount - 1)
        savePosition()
    }
    private func check(_ operation: UUID) throws {
        try Task.checkCancellation()
        if operation != generation || token.isCancelled { throw CancellationError() }
    }
    private func fail(_ error: Error, operation: UUID) {
        guard operation == generation else { return }
        status = nil
        guard !(error is CancellationError) else { return }
        missingCompanion = (error as? ReaderError).map { if case .missingCompanion = $0 { return true }; return false } ?? false
        self.error = error.localizedDescription
    }
    func reloadLocal(annotationsOnly: Bool = false) {
        guard let reference, let local = inputs else { return }
        let operation = begin(reference)
        inputs = local
        task = Task {
            do { try await show(local, operation: operation) }
            catch { fail(error, operation: operation) }
        }
    }
    func savePosition() { if let reference { recents.save(reference, page: page) } }
    func retryRecognition() {
        guard let inputs, displayed != nil, inputs.source.pathExtension.lowercased() != "pdf" else { return }
        cancel(); token = CancellationToken(); warning = nil
        let operation = generation
        task = Task { await enhance(inputs, operation: operation) }
    }
    func background() {
        if recognizing { cancel(); warning = "Recognition paused while the app is in the background." }
    }
    func foreground() {
        if warning == "Recognition paused while the app is in the background." { retryRecognition() }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
