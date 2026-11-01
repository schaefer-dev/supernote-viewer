import XCTest
import PDFKit
import UIKit
@testable import SupernoteViewerIOS

private struct PageRenderer: MobileRendering {
    var failOCR = false
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping RenderProgress) async throws {
        if recognize && failOCR { throw ReaderError.message("OCR failed") }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in context.beginPage() }.write(to: to)
    }
}

@MainActor final class RenderedPDFCacheTests: XCTestCase {
    var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RenderCacheTests-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func cache() -> RenderedPDFCache { RenderedPDFCache(root: root) }
    func entry(_ id: String = "id:a", name: String = "A.note", path: String = "/notes/a.note", revision: String = "rev1") -> RemoteEntry {
        .init(id: id, name: name, path: path, isFolder: false, revision: revision, size: 3)
    }
    func store() -> RecentDocumentsStore { RecentDocumentsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
    func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not become true")
    }
    func cachedFiles() -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "pdf" }
    }
    /// Opens a document and waits until the final (searchable or cached) PDF is displayed and stored.
    func open(_ opener: DocumentOpenCoordinator, _ reference: DocumentReference, service: MockDropbox) async throws {
        opener.openRemote(reference, service: service)
        try await eventually { opener.status == nil && opener.displayed != nil }
    }

    func testUnchangedRevisionReopensWithoutDownloadOrRender() async throws {
        let service = MockDropbox(), file = entry(); service.files[file.id] = file
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: cache())
        let reference = DocumentReference.remote(file, account: "account")
        try await open(opener, reference, service: service)
        try await eventually { self.cachedFiles().count == 1 }
        XCTAssertFalse(opener.metrics.openedFromCache)

        try await open(opener, reference, service: service)
        XCTAssertEqual(service.downloads.count, 1, "An unchanged revision must not be downloaded again")
        XCTAssertTrue(opener.metrics.openedFromCache)
        XCTAssertEqual(opener.displayed?.url.lastPathComponent.hasPrefix("cached-"), true)
        XCTAssertFalse(opener.recognizing)
    }

    func testChangedSourceRevisionMisses() async throws {
        let service = MockDropbox(); var file = entry(); service.files[file.id] = file
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: cache())
        let reference = DocumentReference.remote(file, account: "account")
        try await open(opener, reference, service: service)
        try await eventually { self.cachedFiles().count == 1 }
        file.revision = "rev2"; service.files[file.id] = file
        try await open(opener, reference, service: service)
        try await eventually { opener.displayed?.url.lastPathComponent.hasPrefix("searchable") == true }
        XCTAssertEqual(service.downloads.map(\.revision), ["rev1", "rev2"])
        XCTAssertFalse(opener.metrics.openedFromCache)
    }

    func testCompanionOnlyChangeMisses() async throws {
        let service = MockDropbox()
        let mark = entry("id:m", name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        var pdf = entry("id:p", name: "A.pdf", path: "/notes/a.pdf")
        service.files = [mark.id: mark, pdf.id: pdf]
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: cache())
        let reference = DocumentReference.remote(mark, account: "account")
        service.pages = [.init(entries: [mark, pdf], cursor: "end", hasMore: false)]
        try await open(opener, reference, service: service)
        try await eventually { self.cachedFiles().count == 1 }

        service.pages = [.init(entries: [mark, pdf], cursor: "end", hasMore: false)]
        try await open(opener, reference, service: service)
        XCTAssertTrue(opener.metrics.openedFromCache)
        XCTAssertEqual(service.downloads.count, 2)

        pdf.revision = "changed-companion"; service.files[pdf.id] = pdf
        service.pages = [.init(entries: [mark, pdf], cursor: "end", hasMore: false)]
        try await open(opener, reference, service: service)
        XCTAssertFalse(opener.metrics.openedFromCache)
        XCTAssertEqual(service.downloads.map(\.revision), ["rev1", "rev1", "changed-companion", "rev1"])
    }

    func testOfflineOpenShowsLatestSavedRenderingWithWarning() async throws {
        let service = MockDropbox(), file = entry(); service.files[file.id] = file
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: cache())
        let reference = DocumentReference.remote(file, account: "account")
        try await open(opener, reference, service: service)
        try await eventually { self.cachedFiles().count == 1 }

        service.offline = true
        opener.openRemote(reference, service: service)
        try await eventually { opener.status == nil && opener.metrics.offlineSavedAt != nil }
        XCTAssertNil(opener.error)
        XCTAssertEqual(opener.warning?.hasPrefix("Offline"), true)
        XCTAssertEqual(opener.displayed?.url.lastPathComponent.hasPrefix("cached-"), true)
        XCTAssertEqual(service.downloads.count, 1)
    }

    /// Device regression: a rendering reached only through cache hits (never re-stored by
    /// the current build) must still be found when Dropbox is unreachable.
    func testOfflineFindsRenderingStoredOutsideTheOpenFlowAndPrefersNewest() async throws {
        let subject = cache()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("RenderCacheInputs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        func pdf(_ text: String) throws -> URL {
            let url = outside.appendingPathComponent("\(text).pdf")
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
            try renderer.pdfData { ctx in ctx.beginPage(); (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 12)]) }.write(to: url)
            return url
        }
        let older = try pdf("older"), newer = try pdf("newer")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        // Placed directly, with no bookkeeping beyond the file itself, as on the device.
        let newerKey = RenderCacheKey(accountID: "account", fileID: "id:a", sourceRevision: "rev2", companion: .none)
        let folder = root.appendingPathComponent(newerKey.accountFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: newer, to: folder.appendingPathComponent(newerKey.fileName))
        // Two revisions can coexist when placed outside `store`, e.g. by an earlier build.
        try FileManager.default.linkItem(at: older, to: folder.appendingPathComponent(RenderCacheKey(accountID: "account", fileID: "id:a", sourceRevision: "rev1", companion: .none).fileName))
        subject.store(try pdf("other"), for: RenderCacheKey(accountID: "account", fileID: "id:other", sourceRevision: "rev9", companion: .none))

        let service = MockDropbox(); service.offline = true
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: subject)
        opener.openRemote(.remote(entry(), account: "account"), service: service)
        try await eventually { opener.status == nil && opener.metrics.offlineSavedAt != nil }
        XCTAssertNil(opener.error)
        XCTAssertEqual(opener.metrics.offlineSavedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(opener.displayed?.document.string?.contains("newer"), true)
    }

    func testOfflineOpenWithoutSavedRenderingStillFails() async throws {
        let service = MockDropbox(); service.offline = true
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(), cache: cache())
        opener.openRemote(.remote(entry(), account: "account"), service: service)
        try await eventually { opener.error != nil }
        XCTAssertNil(opener.displayed)
    }

    func testSyncedPreviewOpensInstantlyAndIsUpgraded() async throws {
        let service = MockDropbox(), file = entry(); service.files[file.id] = file
        let subject = cache()
        let key = try XCTUnwrap(DocumentOpenCoordinator.cacheKey(account: "account", source: file, original: nil, annotationsOnly: false))
        let input = root.appendingPathComponent("preview-input.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in context.beginPage() }.write(to: input)
        subject.store(input, for: key.preview)

        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(delay: 100_000_000), cache: subject)
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.displayed?.url.lastPathComponent.hasPrefix("cached-") == true }
        XCTAssertNotNil(opener.status, "The preview is shown while search is being added")
        try await eventually { opener.displayed?.url.lastPathComponent.hasPrefix("searchable") == true && opener.status == nil }
        try await eventually { subject.availability(key) == .searchable }
        XCTAssertEqual(service.downloads.count, 1)
    }

    func testFailedRecognitionIsNotCached() async throws {
        let service = MockDropbox(), file = entry(); service.files[file.id] = file
        let opener = DocumentOpenCoordinator(recents: store(), renderer: PageRenderer(failOCR: true), cache: cache())
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.warning != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(cachedFiles().isEmpty, "A preview without recognition must never be reused as complete")
    }

    func testKeysSeparateAccountsCompanionsAndRendererVersions() {
        let base = RenderCacheKey(accountID: "a", fileID: "id:1", sourceRevision: "r", companion: .none)
        var newer = base; newer.rendererVersion += 1
        XCTAssertNotEqual(base.fileName, newer.fileName)
        XCTAssertNotEqual(base.accountFolder, RenderCacheKey(accountID: "b", fileID: "id:1", sourceRevision: "r", companion: .none).accountFolder)
        XCTAssertNotEqual(RenderCacheKey(accountID: "a", fileID: "id:1", sourceRevision: "r", companion: .annotationsOnly).fileName,
                          RenderCacheKey(accountID: "a", fileID: "id:1", sourceRevision: "r", companion: .original(id: "p", revision: "1")).fileName)
        XCTAssertNil(DocumentOpenCoordinator.cacheKey(account: "a", source: entry(name: "A.pdf.mark"), original: nil, annotationsOnly: false))
    }

    func testStoreKeepsOnlyNewestRevisionAndDisplayedLinksSurvive() throws {
        let subject = cache()
        // Inputs and workspaces live outside the store, as in the app.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("RenderCacheInputs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let workspace = outside.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        func input(_ name: String) throws -> URL {
            let url = outside.appendingPathComponent(name); try Data(repeating: 1, count: 100).write(to: url); return url
        }
        let old = RenderCacheKey(accountID: "a", fileID: "doc", sourceRevision: "r1", companion: .none)
        let new = RenderCacheKey(accountID: "a", fileID: "doc", sourceRevision: "r2", companion: .none)
        let sibling = RenderCacheKey(accountID: "a", fileID: "other", sourceRevision: "r1", companion: .none)
        let other = RenderCacheKey(accountID: "b", fileID: "x", sourceRevision: "r", companion: .none)
        subject.store(try input("old.pdf"), for: old)
        subject.store(try input("sibling.pdf"), for: sibling)
        let displayed = try XCTUnwrap(subject.materialize(old, into: workspace))
        subject.store(try input("new.pdf"), for: new)
        XCTAssertFalse(subject.contains(old), "A superseded revision of the same document is removed")
        XCTAssertTrue(subject.contains(new)); XCTAssertTrue(subject.contains(sibling), "Other documents are kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displayed.path), "Removal must not affect a displayed file")
        XCTAssertEqual(subject.usage().documents, 2)

        subject.store(try input("other.pdf"), for: other)
        subject.removeAll(accountID: "a")
        XCTAssertFalse(subject.contains(new)); XCTAssertTrue(subject.contains(other))
        subject.removeEverything()
        XCTAssertEqual(subject.usage().documents, 0)
    }

    func testLegacyCacheRenderingsAreAdopted() throws {
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyRenderings-\(UUID().uuidString)")
        let key = RenderCacheKey(accountID: "a", fileID: "doc", sourceRevision: "r", companion: .none)
        let folder = legacy.appendingPathComponent(key.accountFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent(key.fileName))
        let subject = cache()
        subject.adoptLegacyRenderings(from: legacy)
        XCTAssertTrue(subject.contains(key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
