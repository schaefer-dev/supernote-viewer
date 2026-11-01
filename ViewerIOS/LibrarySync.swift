import BackgroundTasks
import Foundation
import Observation

/// One document that needs a fresh rendering to be available offline.
struct SyncItem: Sendable {
    let source: RemoteEntry
    let original: RemoteEntry?
    let key: RenderCacheKey
    var bytes: UInt64 { source.size + (original?.size ?? 0) }
}

/// What a sync would do, shown to the user before anything is downloaded.
struct SyncPlan: Sendable {
    let items: [SyncItem]
    /// Supported documents already saved in their current revision.
    let upToDate: Int
    /// Annotations whose original PDF is not beside them; they cannot be rendered completely.
    let missingOriginals: Int
    var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

/// Makes every document in the library folder available offline: lists it recursively,
/// downloads each document whose current revision is not saved, recognizes handwriting and
/// stores the searchable PDF. Runs in the foreground and, where iOS allows, continues in the
/// background as a continued-processing task with system progress.
@Observable @MainActor final class LibrarySync {
    enum Phase: Equatable { case idle, checking, ready, running, finished, failed }
    private(set) var phase = Phase.idle
    private(set) var plan: SyncPlan?
    /// Fraction of the whole run, including progress inside the current document.
    private(set) var fraction = 0.0
    private(set) var completed = 0
    private(set) var current: String?
    private(set) var failures: [String] = []
    private(set) var message: String?

    /// Called after each saved rendering, so lists and thumbnails can refresh.
    @ObservationIgnored var renderingSaved: ((RenderCacheKey) -> Void)?
    /// While this returns true (a document is being opened), sync waits between documents.
    @ObservationIgnored var readerIsBusy: () -> Bool = { false }

    @ObservationIgnored private let cache: RenderedPDFCache
    @ObservationIgnored private let renderer: any MobileRendering
    @ObservationIgnored private let scheduler: (any ContinuedProcessing)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = CancellationToken()
    @ObservationIgnored private var background: (any ContinuedProcessingHandle)?

    init(cache: RenderedPDFCache, renderer: any MobileRendering, scheduler: (any ContinuedProcessing)? = nil) {
        self.cache = cache; self.renderer = renderer; self.scheduler = scheduler
    }

    var isActive: Bool { phase == .checking || phase == .running }

    /// Lists the library folder and works out which documents need downloading.
    func check(service: any DropboxService, account: String, root: RemoteEntry?) async {
        guard !isActive else { return }
        phase = .checking; plan = nil; message = nil; failures = []; completed = 0; fraction = 0
        do {
            let entries = try await allEntries(service: service, path: root?.id ?? "", recursive: true)
            let documents = LibraryItem.group(entries).filter { !$0.entry.isFolder }
            var candidates: [SyncItem] = [], missing = 0
            for item in documents {
                guard let key = DocumentOpenCoordinator.cacheKey(account: account, source: item.entry, original: item.original, annotationsOnly: false) else {
                    if item.entry.isAnnotation { missing += 1 }
                    continue
                }
                candidates.append(SyncItem(source: item.entry, original: item.original, key: key))
            }
            let cache = self.cache
            let needed = await Task.detached(priority: .userInitiated) { candidates.filter { !cache.contains($0.key) } }.value
            plan = SyncPlan(items: needed, upToDate: candidates.count - needed.count, missingOriginals: missing)
            phase = needed.isEmpty ? .finished : .ready
            if needed.isEmpty { message = "All \(candidates.count) documents are already available offline." }
        } catch {
            phase = .failed
            message = error is CancellationError ? nil : error.localizedDescription
        }
    }

    /// Starts downloading the checked plan.
    func start(service: any DropboxService) {
        guard phase == .ready, let plan, !plan.items.isEmpty else { return }
        phase = .running; completed = 0; fraction = 0; failures = []; message = nil
        token = CancellationToken()
        let token = self.token
        background = scheduler?.begin(title: "Syncing Supernote library",
                                      subtitle: "\(plan.items.count) documents") { [weak self] in
            self?.cancel(reason: "iOS paused the sync. Open Sync again to continue where it stopped.")
        }
        task = Task { await run(plan.items, service: service, token: token) }
    }

    func cancel(reason: String? = nil) {
        guard isActive else { return }
        token.cancel(); task?.cancel()
        phase = .failed
        message = reason ?? "Sync canceled. Documents finished so far stay available offline."
        current = nil
        finishBackground(success: false)
    }

    func dismiss() { if !isActive { phase = .idle; plan = nil; message = nil; failures = [] } }

    private func run(_ items: [SyncItem], service: any DropboxService, token: CancellationToken) async {
        let total = Double(items.count)
        for (index, item) in items.enumerated() {
            while readerIsBusy() && !token.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
            guard !token.isCancelled else { return }
            current = displayName(item.source.name)
            report(index: index, inside: 0, total: total)
            do {
                try await sync(item, service: service, token: token) { [weak self] inside in
                    self?.report(index: index, inside: inside, total: total)
                }
                completed += 1
                renderingSaved?(item.key)
            } catch {
                guard !token.isCancelled, !(error is CancellationError) else { return }
                if case ReaderError.offline = error {
                    phase = .failed; current = nil
                    message = "Dropbox could not be reached. \(completed) of \(items.count) documents were synced; run Sync again when connected."
                    finishBackground(success: false); return
                }
                if case ReaderError.rateLimited = error {
                    phase = .failed; current = nil
                    message = error.localizedDescription
                    finishBackground(success: false); return
                }
                failures.append(displayName(item.source.name))
            }
        }
        current = nil; fraction = 1; phase = .finished
        message = failures.isEmpty
            ? "\(completed) documents synced. Your library is available offline."
            : "\(completed) documents synced; \(failures.count) could not be synced."
        finishBackground(success: failures.isEmpty)
    }

    private func sync(_ item: SyncItem, service: any DropboxService, token: CancellationToken,
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        let workspace = try Workspace()
        // Downloads count for the first fifth of a document; recognition for the rest.
        let original = try await item.original.asyncMap { original in
            try await downloadSnapshot(original, service: service, into: workspace.url, name: "original.pdf") { fraction in
                Task { @MainActor in progress(0.1 * fraction) }
            }
        }
        let extensionName = (item.source.name as NSString).pathExtension
        let source = try await downloadSnapshot(item.source, service: service, into: workspace.url, name: "source." + extensionName) { fraction in
            Task { @MainActor in progress(0.1 + 0.1 * fraction) }
        }
        guard !token.isCancelled else { throw CancellationError() }
        let cache = self.cache, key = item.key
        if extensionName.lowercased() == "pdf" {
            await Task.detached(priority: .utility) { cache.store(source, for: key) }.value
            return
        }
        let output = workspace.url.appendingPathComponent("searchable.pdf")
        try await renderer.render(LocalInputs(source: source, companion: original, workspace: workspace), to: output,
                                  recognize: true, token: token) { _, fraction in
            if let fraction { Task { @MainActor in progress(0.2 + 0.8 * fraction) } }
        }
        guard !token.isCancelled else { throw CancellationError() }
        await Task.detached(priority: .utility) { cache.store(output, for: key) }.value
    }

    private func report(index: Int, inside: Double, total: Double) {
        guard phase == .running else { return }
        fraction = min(1, (Double(index) + inside) / total)
        background?.update(fraction: fraction, subtitle: "\(index + 1) of \(Int(total)) · \(current ?? "")")
    }

    private func finishBackground(success: Bool) {
        background?.finish(success: success); background = nil
    }
}

// MARK: - Continued processing

/// Keeps a user-started job running after the app leaves the foreground.
@MainActor protocol ContinuedProcessing {
    /// Returns a handle while iOS runs the job as a continued-processing task, or nil.
    func begin(title: String, subtitle: String, expiration: @escaping @MainActor () -> Void) -> (any ContinuedProcessingHandle)?
}
@MainActor protocol ContinuedProcessingHandle: AnyObject {
    func update(fraction: Double, subtitle: String)
    func finish(success: Bool)
}

/// Uses iOS 26 continued-processing tasks, which show the system progress UI and may keep
/// running when the user switches apps. If iOS declines, sync simply runs in the foreground.
struct SystemContinuedProcessing: ContinuedProcessing {
    /// Must match the wildcard in `BGTaskSchedulerPermittedIdentifiers`.
    static let identifierPrefix = "dev.schaefer.SupernoteViewerIOS.sync."

    func begin(title: String, subtitle: String, expiration: @escaping @MainActor () -> Void) -> (any ContinuedProcessingHandle)? {
        let handle = SystemContinuedProcessingHandle()
        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                task.expirationHandler = { MainActor.assumeIsolated { expiration() } }
                handle.attach(task)
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { return nil }
        return handle
    }
}

@MainActor final class SystemContinuedProcessingHandle: ContinuedProcessingHandle {
    private var task: BGContinuedProcessingTask?
    private var pending: (fraction: Double, subtitle: String)?
    private var finished: Bool?
    private static let units: Int64 = 1000

    func attach(_ task: BGContinuedProcessingTask) {
        if let finished { task.setTaskCompleted(success: finished); return }
        self.task = task
        task.progress.totalUnitCount = Self.units
        if let pending { update(fraction: pending.fraction, subtitle: pending.subtitle) }
    }
    func update(fraction: Double, subtitle: String) {
        guard let task else { pending = (fraction, subtitle); return }
        task.progress.completedUnitCount = Int64(fraction * Double(Self.units))
        task.updateTitle(task.title, subtitle: subtitle)
    }
    func finish(success: Bool) {
        if let task { task.setTaskCompleted(success: success); self.task = nil } else { finished = success }
    }
}
