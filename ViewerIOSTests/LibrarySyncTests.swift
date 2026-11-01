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

    func testPlanSkipsSavedDocumentsAndRunSyncsTheRest() async throws {
        let cache = RenderedPDFCache(root: root)
        let saved = entry("id:saved", "Saved.note"), fresh = entry("id:fresh", "Fresh.note", folder: "/supernote/note/sub")
        let mark = entry("id:mark", "Paper.pdf.mark", folder: "/supernote/document"), pdf = entry("id:pdf", "Paper.pdf", folder: "/supernote/document")
        let orphan = entry("id:orphan", "Lonely.pdf.mark", folder: "/supernote/document")
        let broken = entry("id:broken", "broken.note")
        let folder = RemoteEntry(id: "id:sub", name: "sub", path: "/supernote/note/sub", isFolder: true)
        let service = MockDropbox()
        service.pages = [.init(entries: [saved, fresh, mark, pdf, orphan, broken, folder], cursor: "end", hasMore: false)]
        // "Saved" already has its current revision on the device.
        let input = root.appendingPathComponent("input.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: input)
        cache.store(input, for: try XCTUnwrap(DocumentOpenCoordinator.cacheKey(account: "acc", source: saved, original: nil, annotationsOnly: false)))

        let background = FakeContinuedProcessing()
        // "broken" sorts first among the documents to sync, so its render is the one that fails.
        let sync = LibrarySync(cache: cache, renderer: SyncRenderer(failures: 1), scheduler: background)
        var saves: [String] = []
        sync.renderingSaved = { saves.append($0.fileID) }
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(service.recursiveCalls, 1, "The library is listed recursively")
        XCTAssertEqual(sync.phase, .ready)
        let plan = try XCTUnwrap(sync.plan)
        XCTAssertEqual(Set(plan.items.map(\.source.id)), ["id:fresh", "id:mark", "id:broken"])
        XCTAssertEqual(plan.upToDate, 1); XCTAssertEqual(plan.missingOriginals, 1)
        XCTAssertEqual(plan.items.first { $0.source.id == "id:mark" }?.original?.id, "id:pdf")

        sync.start(service: service)
        try await eventually { sync.phase == .finished }
        XCTAssertEqual(sync.completed, 2)
        XCTAssertEqual(sync.failures, ["broken"], "A failing document is reported and the rest continue")
        XCTAssertEqual(Set(saves), ["id:fresh", "id:mark"])
        XCTAssertEqual(service.downloads.map(\.id).sorted(), ["id:broken", "id:fresh", "id:mark", "id:pdf"])
        XCTAssertEqual(sync.fraction, 1)
        XCTAssertEqual(background.finished, false, "Partial success is reported to iOS")
        XCTAssertFalse(background.updates.isEmpty)

        service.pages = [.init(entries: [saved, fresh, mark, pdf], cursor: "end", hasMore: false)]
        await sync.check(service: service, account: "acc", root: nil)
        XCTAssertEqual(sync.phase, .finished, "A second check finds nothing left to download")
        XCTAssertEqual(sync.plan?.upToDate, 3)
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
