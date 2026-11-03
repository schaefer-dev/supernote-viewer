import BackgroundTasks
import Foundation
import Observation

/// One document that is not yet saved in its current revision as a searchable PDF.
struct SyncItem: Sendable {
    let source: RemoteEntry
    let original: RemoteEntry?
    let key: RenderCacheKey
    /// Nothing readable is saved yet for these revisions.
    let needsReadableCopy: Bool
    var bytes: UInt64 { source.size + (original?.size ?? 0) }
    /// Ordinary PDFs are saved as they are; only Supernote documents need recognition.
    var isPDF: Bool { (source.name as NSString).pathExtension.lowercased() == "pdf" }
    var modified: Date { [source.modified, original?.modified].compactMap { $0 }.max() ?? .distantPast }
}

/// What a sync would do, shown to the user before anything is downloaded.
struct SyncPlan: Sendable {
    /// Newest first, so recently changed documents are ready earliest.
    let items: [SyncItem]
    /// Supported documents already saved, searchable, in their current revision.
    let upToDate: Int
    /// Annotations whose original PDF is not beside them; they cannot be rendered completely.
    let missingOriginals: Int
    var readablePass: [SyncItem] { items.filter(\.needsReadableCopy) }
    var searchablePass: [SyncItem] { items.filter { !$0.isPDF } }
    var downloadBytes: UInt64 { readablePass.reduce(0) { $0 + $1.bytes } }
}

/// Wall-clock time spent waiting for downloads, rendering pages and recognizing handwriting.
struct SyncTimings: Equatable, Sendable {
    var waitingForDownloads: TimeInterval = 0
    var rendering: TimeInterval = 0
    var recognizing: TimeInterval = 0
}

/// Makes every document in the library folder available offline, in two passes:
/// 1. **Readable:** download and render each document without handwriting recognition and
///    save that preview, so the whole library opens offline quickly.
/// 2. **Searchable:** download again and recognize handwriting, replacing each preview.
/// Both passes go newest first and download a few documents ahead of rendering. Rendering
/// uses a higher priority while the app is in the foreground. Where iOS allows, the run
/// continues in the background as a continued-processing task with system progress.
@Observable @MainActor final class LibrarySync {
    enum Phase: Equatable { case idle, checking, ready, running, finished, failed }
    enum Pass: Equatable { case readable, searchable }
    private(set) var phase = Phase.idle
    private(set) var plan: SyncPlan?
    private(set) var pass = Pass.readable
    /// Fraction of the whole run across both passes.
    private(set) var fraction = 0.0
    /// Documents finished in the current pass, and that pass's size.
    private(set) var completed = 0
    private(set) var passTotal = 0
    private(set) var current: String?
    private(set) var failures: [String] = []
    /// Documents that are readable offline but whose handwriting could not be recognized.
    private(set) var unsearchable: [String] = []
    private(set) var message: String?
    private(set) var timings = SyncTimings()

    /// Called after each saved rendering, so lists and thumbnails can refresh.
    @ObservationIgnored var renderingSaved: ((RenderCacheKey) -> Void)?
    /// While this returns true (a document is being opened), sync waits between documents.
    @ObservationIgnored var readerIsBusy: () -> Bool = { false }
    /// The app is in the foreground: render at the higher priority.
    @ObservationIgnored var inForeground = true

    @ObservationIgnored private let cache: RenderedPDFCache
    @ObservationIgnored private let foregroundRenderer: any MobileRendering
    @ObservationIgnored private let backgroundRenderer: any MobileRendering
    @ObservationIgnored private let scheduler: (any ContinuedProcessing)?
    @ObservationIgnored private let lookahead: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = CancellationToken()
    @ObservationIgnored private var background: (any ContinuedProcessingHandle)?
    @ObservationIgnored private var unitsDone = 0.0
    @ObservationIgnored private var unitsTotal = 1.0
    /// Recognition takes far longer than rendering, so it weighs more in overall progress.
    private static let recognitionWeight = 3.0

    init(cache: RenderedPDFCache, renderer: any MobileRendering, backgroundRenderer: (any MobileRendering)? = nil,
         scheduler: (any ContinuedProcessing)? = nil, lookahead: Int = 4) {
        self.cache = cache; self.foregroundRenderer = renderer
        self.backgroundRenderer = backgroundRenderer ?? renderer
        self.scheduler = scheduler; self.lookahead = max(1, lookahead)
    }

    var isActive: Bool { phase == .checking || phase == .running }

    /// Lists the library folder and works out what each document still needs.
    func check(service: any DropboxService, account: String, root: RemoteEntry?) async {
        guard !isActive else { return }
        phase = .checking; plan = nil; message = nil; failures = []; unsearchable = []
        completed = 0; passTotal = 0; fraction = 0; timings = SyncTimings()
        do {
            let entries = try await allEntries(service: service, path: root?.id ?? "", recursive: true)
            let documents = LibraryItem.group(entries).filter { !$0.entry.isFolder }
            var candidates: [(LibraryItem, RenderCacheKey)] = [], missing = 0
            for item in documents {
                guard let key = DocumentOpenCoordinator.cacheKey(account: account, source: item.entry, original: item.original, annotationsOnly: false) else {
                    if item.entry.isAnnotation { missing += 1 }
                    continue
                }
                candidates.append((item, key))
            }
            let cache = self.cache
            let keys = candidates.map(\.1)
            let saved = await Task.detached(priority: .userInitiated) { keys.map { cache.availability($0) } }.value
            var items: [SyncItem] = [], upToDate = 0
            for ((item, key), availability) in zip(candidates, saved) {
                switch availability {
                case .searchable: upToDate += 1
                case .preview: items.append(SyncItem(source: item.entry, original: item.original, key: key, needsReadableCopy: false))
                case .none: items.append(SyncItem(source: item.entry, original: item.original, key: key, needsReadableCopy: true))
                }
            }
            items.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.source.name.localizedStandardCompare($1.source.name) == .orderedAscending }
            plan = SyncPlan(items: items, upToDate: upToDate, missingOriginals: missing)
            phase = items.isEmpty ? .finished : .ready
            if items.isEmpty { message = "All \(upToDate) documents are already available offline and searchable." }
        } catch {
            phase = .failed
            message = error is CancellationError ? nil : error.localizedDescription
        }
    }

    /// Starts both passes for the checked plan.
    func start(service: any DropboxService) {
        guard phase == .ready, let plan, !plan.items.isEmpty else { return }
        phase = .running; completed = 0; fraction = 0; failures = []; unsearchable = []; message = nil
        timings = SyncTimings(); unitsDone = 0
        let readable = plan.readablePass
        unitsTotal = max(1, Double(readable.count) + Self.recognitionWeight * Double(plan.searchablePass.count))
        token = CancellationToken()
        let token = self.token
        background = scheduler?.begin(title: "Syncing Supernote library",
                                      subtitle: "\(plan.items.count) documents") { [weak self] in
            self?.cancel(reason: "iOS paused the sync. Documents finished so far stay available; run Sync again to continue.")
        }
        task = Task { await run(plan, service: service, token: token) }
    }

    func cancel(reason: String? = nil) {
        guard isActive else { return }
        token.cancel(); task?.cancel()
        phase = .failed
        message = reason ?? "Sync canceled. Documents finished so far stay available offline."
        current = nil
        finishBackground(success: false)
    }

    func dismiss() { if !isActive { phase = .idle; plan = nil; message = nil; failures = []; unsearchable = [] } }

    private func run(_ plan: SyncPlan, service: any DropboxService, token: CancellationToken) async {
        pass = .readable
        guard await runPass(plan.readablePass, recognize: false, service: service, token: token) else { return }
        let failed = Set(failures)
        pass = .searchable
        // Documents that could not be rendered at all are not retried for recognition.
        let searchable = plan.searchablePass.filter { !failed.contains(displayName($0.source.name)) }
        guard await runPass(searchable, recognize: true, service: service, token: token) else { return }
        current = nil; fraction = 1; phase = .finished
        let readableCount = plan.items.count - failures.count
        var summary = failures.isEmpty
            ? "\(readableCount) documents are available offline."
            : "\(readableCount) documents are available offline; \(failures.count) could not be synced."
        if !unsearchable.isEmpty { summary += " \(unsearchable.count) are readable but not searchable." }
        message = summary
        finishBackground(success: failures.isEmpty && unsearchable.isEmpty)
    }

    private struct Downloaded {
        let workspace: Workspace
        let source: URL
        let original: URL?
    }

    /// Runs one pass, downloading up to `lookahead` documents ahead of rendering.
    /// Returns false when the run stopped (canceled, offline or rate limited).
    private func runPass(_ items: [SyncItem], recognize: Bool, service: any DropboxService, token: CancellationToken) async -> Bool {
        completed = 0; passTotal = items.count
        var downloads: [Int: Task<Downloaded, Error>] = [:]
        defer { downloads.values.forEach { $0.cancel() } }
        let weight = recognize ? Self.recognitionWeight : 1
        for (index, item) in items.enumerated() {
            while readerIsBusy() && !token.isCancelled { try? await Task.sleep(for: .milliseconds(500)) }
            guard !token.isCancelled else { return false }
            for ahead in index..<min(index + lookahead, items.count) where downloads[ahead] == nil {
                downloads[ahead] = Self.download(items[ahead], service: service)
            }
            current = displayName(item.source.name)
            report(inside: 0, weight: weight)
            do {
                let waitStarted = Date()
                guard let pending = downloads.removeValue(forKey: index) else { continue }
                let downloaded = try await pending.value
                timings.waitingForDownloads += Date().timeIntervalSince(waitStarted)
                guard !token.isCancelled else { return false }
                let renderStarted = Date()
                try await save(item, downloaded, recognize: recognize, token: token) { [weak self] inside in
                    self?.report(inside: inside, weight: weight)
                }
                let elapsed = Date().timeIntervalSince(renderStarted)
                if recognize { timings.recognizing += elapsed } else { timings.rendering += elapsed }
                renderingSaved?(item.key)
            } catch {
                guard !token.isCancelled, !(error is CancellationError) else { return false }
                if case ReaderError.offline = error { return stop("Dropbox could not be reached. Documents finished so far stay available; run Sync again when connected.") }
                if case ReaderError.rateLimited = error { return stop(error.localizedDescription) }
                if recognize { unsearchable.append(displayName(item.source.name)) }
                else { failures.append(displayName(item.source.name)) }
            }
            completed += 1
            unitsDone += weight
            report(inside: 0, weight: weight)
        }
        return true
    }

    private func stop(_ reason: String) -> Bool {
        phase = .failed; current = nil; message = reason
        finishBackground(success: false)
        return false
    }

    private static func download(_ item: SyncItem, service: any DropboxService) -> Task<Downloaded, Error> {
        Task { @MainActor in
            let workspace = try Workspace()
            let original = try await item.original.asyncMap {
                try await downloadSnapshot($0, service: service, into: workspace.url, name: "original.pdf") { _ in }
            }
            let source = try await downloadSnapshot(item.source, service: service, into: workspace.url,
                                                    name: "source." + (item.source.name as NSString).pathExtension) { _ in }
            return Downloaded(workspace: workspace, source: source, original: original)
        }
    }

    private func save(_ item: SyncItem, _ downloaded: Downloaded, recognize: Bool, token: CancellationToken,
                      progress: @escaping @MainActor (Double) -> Void) async throws {
        let cache = self.cache
        if item.isPDF {
            // An ordinary PDF is already final and searchable.
            let key = item.key.searchable, source = downloaded.source
            await Task.detached(priority: .utility) { cache.store(source, for: key) }.value
            return
        }
        let output = downloaded.workspace.url.appendingPathComponent(recognize ? "searchable.pdf" : "readable.pdf")
        let renderer = inForeground ? foregroundRenderer : backgroundRenderer
        try await renderer.render(LocalInputs(source: downloaded.source, companion: downloaded.original, workspace: downloaded.workspace),
                                  to: output, recognize: recognize, token: token) { _, fraction in
            if let fraction { Task { @MainActor in progress(fraction) } }
        }
        guard !token.isCancelled else { throw CancellationError() }
        let key = recognize ? item.key.searchable : item.key.preview
        await Task.detached(priority: .utility) { cache.store(output, for: key) }.value
    }

    private func report(inside: Double, weight: Double) {
        guard phase == .running else { return }
        fraction = min(1, (unitsDone + inside * weight) / unitsTotal)
        let step = pass == .readable ? "Making readable" : "Adding search"
        background?.update(fraction: fraction, subtitle: "\(step) · \(min(completed + 1, passTotal)) of \(passTotal) · \(current ?? "")")
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
