import XCTest
import UIKit
@testable import SupernoteViewerIOS

/// Fails the first `failures` renders. Sync processes documents in name order and stores
/// sources under generic names, so failures are selected by order, not file name.
private final class SyncRenderer: MobileRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    init(failures: Int = 0) { remainingFailures = failures }
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping RenderProgress) async throws {
        progress("Recognizing", 0.5)
        let fail = lock.withLock { () -> Bool in
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1; return true
        }
        if fail { throw ReaderError.message("Recognition failed") }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in context.beginPage() }.write(to: to)
    }
}

/// Records whether each render recognized handwriting.
private final class RecordingRenderer: MobileRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [Bool] = []
    var recognizeFlags: [Bool] { lock.withLock { flags } }
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping RenderProgress) async throws {
        lock.withLock { flags.append(recognize) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in context.beginPage() }.write(to: to)
    }
}

@MainActor private final class FakeContinuedProcessing: ContinuedProcessing, ContinuedProcessingHandle {
    var updates: [Double] = []
    var finished: Bool?
    var expiration: (@MainActor () -> Void)?
    func begin(title: String, subtitle: String, expiration: @escaping @MainActor () -> Void) -> (any ContinuedProcessingHandle)? {
        self.expiration = expiration; return self
    }
    func update(fraction: Double, subtitle: String) { updates.append(fraction) }
    func finish(success: Bool) { finished = success }
}

@MainActor final class LibrarySyncTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTests-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func entry(_ id: String, _ name: String, folder: String = "/supernote/note", revision: String = "rev1") -> RemoteEntry {
        .init(id: id, name: name, path: "\(folder)/\(name.lowercased())", isFolder: false, revision: revision, size: 3)
    }
    func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not become true")
    }

    func testTwoPassesMakeEverythingReadableThenSearchable() async throws {
        let cache = RenderedPDFCache(root: root)
        let saved = entry("id:saved", "Saved.note"), fresh = entry("id:fresh", "Fresh.note", folder: "/supernote/note/sub")
        let mark = entry("id:mark", "Paper.pdf.mark", folder: "/supernote/document"), pdf = entry("id:pdf", "Paper.pdf", folder: "/supernote/document")
        let orphan = entry("id:orphan", "Lonely.pdf.mark", folder: "/supernote/document")
        let broken = entry("id:broken", "broken.note"), previewOnly = entry("id:preview", "PreviewOnly.note")
        let folder = RemoteEntry(id: "id:sub", name: "sub", path: "/supernote/note/sub", isFolder: true)
        let service = MockDropbox()
        service.pages = [.init(entries: [saved, fresh, mark, pdf, orphan, broken, previewOnly, folder], cursor: "end", hasMore: false)]
        let input = root.appendingPathComponent("input.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: input)
        func key(_ entry: RemoteEntry, original: RemoteEntry? = nil) throws -> RenderCacheKey {
            try XCTUnwrap(DocumentOpenCoordinator.cacheKey(account: "acc", source: entry, original: original, annotationsOnly: false))
        }
        // "Saved" is searchable already; "PreviewOnly" is readable but needs recognition.
        cache.store(input, for: try key(saved))
        cache.store(input, for: try key(previewOnly).preview)

        let background = FakeContinuedProcessing()
        // Sorted by name (no dates): broken, Fresh, Paper, PreviewOnly. The first render (broken) fails.
        let sync = LibrarySync(cache: cache, renderer: SyncRenderer(failures: 1), scheduler: background)
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(service.recursiveCalls, 1, "The library is listed recursively")
        XCTAssertEqual(sync.phase, .ready)
        let plan = try XCTUnwrap(sync.plan)
        XCTAssertEqual(plan.items.map(\.source.id), ["id:broken", "id:fresh", "id:mark", "id:preview"])
        XCTAssertEqual(plan.readablePass.map(\.source.id), ["id:broken", "id:fresh", "id:mark"])
        XCTAssertEqual(plan.searchablePass.count, 4)
        XCTAssertEqual(plan.upToDate, 1); XCTAssertEqual(plan.missingOriginals, 1)

        sync.start(service: service)
        try await eventually { sync.phase == .finished }
        XCTAssertEqual(sync.failures, ["broken"], "A failing document is reported and the rest continue")
        XCTAssertTrue(sync.unsearchable.isEmpty)
        XCTAssertEqual(cache.availability(try key(fresh)), .searchable)
        XCTAssertEqual(cache.availability(try key(mark, original: pdf)), .searchable)
        XCTAssertEqual(cache.availability(try key(previewOnly)), .searchable, "Recognition upgrades an existing preview")
        XCTAssertEqual(cache.availability(try key(broken)), .none)
        // Downloads overlap within a pass, so compare each pass without its order.
        let ids = service.downloads.map(\.id)
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(ids.prefix(4).sorted(), ["id:broken", "id:fresh", "id:mark", "id:pdf"], "Readable pass first")
        XCTAssertEqual(ids.suffix(4).sorted(), ["id:fresh", "id:mark", "id:pdf", "id:preview"],
                       "Then the recognition pass; the failed document is not retried")
        XCTAssertEqual(sync.fraction, 1)
        XCTAssertEqual(background.finished, false, "Partial success is reported to iOS")
        XCTAssertFalse(background.updates.isEmpty)

        service.pages = [.init(entries: [saved, fresh, mark, pdf, previewOnly], cursor: "end", hasMore: false)]
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(sync.phase, .finished, "A second check finds nothing left to do")
        XCTAssertEqual(sync.plan?.upToDate, 4)
    }

    func testReadablePassFinishesBeforeRecognitionNewestFirstAndUsesForegroundPriority() async throws {
        let cache = RenderedPDFCache(root: root)
        var old = entry("id:old", "Old.note"); old.modified = Date(timeIntervalSince1970: 1_000)
        var new = entry("id:new", "New.note"); new.modified = Date(timeIntervalSince1970: 9_000)
        let service = MockDropbox()
        service.pages = [.init(entries: [old, new], cursor: "end", hasMore: false)]
        let foreground = RecordingRenderer(), backgroundRenderer = RecordingRenderer()
        let sync = LibrarySync(cache: cache, renderer: foreground, backgroundRenderer: backgroundRenderer)
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(sync.plan?.items.map(\.source.id), ["id:new", "id:old"], "Newest documents first")
        sync.start(service: service)
        try await eventually { sync.phase == .finished }
        XCTAssertEqual(foreground.recognizeFlags, [false, false, true, true], "Everything is readable before recognition starts")
        XCTAssertTrue(backgroundRenderer.recognizeFlags.isEmpty)
        XCTAssertGreaterThan(sync.timings.rendering + sync.timings.recognizing, 0)

        // In the background the lower-priority renderer is used.
        var newer = new; newer.revision = "rev2"
        service.pages = [.init(entries: [old, newer], cursor: "end", hasMore: false)]
        await sync.check(service: service, account: "acc", root: nil)
        sync.inForeground = false
        sync.start(service: service)
        try await eventually { sync.phase == .finished }
        XCTAssertEqual(backgroundRenderer.recognizeFlags, [false, true])
    }

    func testOfflineStopsSyncAndExpirationCancels() async throws {
        let cache = RenderedPDFCache(root: root)
        let service = MockDropbox()
        service.pages = [.init(entries: [entry("id:a", "A.note"), entry("id:b", "B.note")], cursor: "end", hasMore: false)]
        let background = FakeContinuedProcessing()
        let sync = LibrarySync(cache: cache, renderer: SyncRenderer(), scheduler: background)
        await sync.check(service: service, account: "acc", root: nil)
        service.delay = 50_000_000
        sync.start(service: service)
        background.expiration?()
        XCTAssertEqual(sync.phase, .failed)
        XCTAssertTrue(sync.message?.contains("paused") == true)
        XCTAssertEqual(background.finished, false)

        service.offline = true
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(sync.phase, .failed)
        XCTAssertEqual(sync.message, "Could not reach Dropbox.", "The offline reason is shown, not a generic failure")
    }

    func testSyncWaitsWhileADocumentIsOpening() async throws {
        let cache = RenderedPDFCache(root: root)
        let service = MockDropbox()
        service.pages = [.init(entries: [entry("id:a", "A.note")], cursor: "end", hasMore: false)]
        let sync = LibrarySync(cache: cache, renderer: SyncRenderer())
        var busy = true
        sync.readerIsBusy = { busy }
        await sync.check(service: service, account: "acc", root: nil)
        sync.start(service: service)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(service.downloads.isEmpty, "Sync must not compete with opening a document")
        busy = false
        try await eventually { sync.phase == .finished }
        XCTAssertEqual(sync.completed, 1)
    }
}
