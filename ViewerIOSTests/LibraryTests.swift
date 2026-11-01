import XCTest
import PDFKit
import UIKit
@testable import SupernoteViewerIOS

@MainActor final class MockDropbox: DropboxService {
    var pages: [FolderPage] = []
    var calls: [(String, String?)] = []
    var files: [String: RemoteEntry] = [:]
    var downloads: [RemoteEntry] = []
    var payload = Data([1, 2, 3])
    var wrongRevision = false
    var delay: UInt64 = 0
    var offline = false
    var metadataRequests: [String] = []
    var recursiveCalls = 0
    func list(path: String, cursor: String?, recursive: Bool) async throws -> FolderPage {
        if offline { throw ReaderError.offline("Could not reach Dropbox.") }
        if recursive { recursiveCalls += 1 }
        calls.append((path, cursor)); return pages.removeFirst()
    }
    func metadata(id: String) async throws -> RemoteEntry {
        if offline { throw ReaderError.offline("Could not reach Dropbox.") }
        metadataRequests.append(id)
        // Dropbox accepts either an ID or a case-insensitive path.
        guard let file = files[id] ?? files.values.first(where: { $0.path == id.lowercased() }) else { throw ReaderError.message("File missing") }
        return file
    }
    func download(_ entry: RemoteEntry, to: URL, progress: @escaping (Double) -> Void) async throws -> RemoteEntry {
        downloads.append(entry)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        try payload.write(to: to); progress(1)
        var value = entry
        if wrongRevision { value.revision = "wrong" }
        return value
    }
}

@MainActor final class ManualBackgroundTime: BackgroundTime {
    let grants: Bool
    private(set) var active = 0
    private var expirations: [@MainActor () -> Void] = []
    init(grants: Bool) { self.grants = grants }
    func begin(expiration: @escaping @MainActor () -> Void) -> Int? {
        guard grants else { return nil }
        active += 1; expirations.append(expiration); return active
    }
    func end(_ token: Int) { active -= 1 }
    func expire() { let pending = expirations; expirations = []; pending.forEach { $0() } }
}

struct FakeRenderer: MobileRendering {
    var failOCR = false
    var delay: UInt64 = 0
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping RenderProgress) async throws {
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if recognize && failOCR { throw ReaderError.message("OCR failed") }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in context.beginPage() }.write(to: to)
    }
}

@MainActor final class LibraryTests: XCTestCase {
    func entry(_ id: String = "id:a", name: String = "A.note", path: String = "/notes/a.note", revision: String = "rev1") -> RemoteEntry {
        .init(id: id, name: name, path: path, isFolder: false, revision: revision, size: 3)
    }
    func store() -> RecentDocumentsStore { RecentDocumentsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!) }
    func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not become true")
    }
    func testPaginationGroupingAndSameParentCompanions() async throws {
        let service = MockDropbox()
        let original = entry("id:p", name: "A.pdf", path: "/notes/a.pdf")
        let mark = entry("id:m", name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        let unrelated = entry("id:q", name: "A.pdf", path: "/other/a.pdf")
        service.pages = [.init(entries: [mark], cursor: "next", hasMore: true), .init(entries: [original, unrelated], cursor: "end", hasMore: false)]
        let all = try await allEntries(service: service, path: "id:folder")
        XCTAssertEqual(service.calls.count, 2); XCTAssertEqual(service.calls[1].1, "next")
        let grouped = LibraryItem.group(all)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped.first { $0.entry.id == mark.id }?.original?.id, original.id)
        XCTAssertTrue(grouped.contains { $0.id == unrelated.id })
    }
    func testTwoStagesRetainPreviewAfterOCRFailure() async throws {
        let service = MockDropbox(); let file = entry(); service.files[file.id] = file
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(failOCR: true))
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.warning != nil }
        XCTAssertEqual(opener.displayed?.url.lastPathComponent.hasPrefix("preview"), true)
        XCTAssertFalse(opener.recognizing); XCTAssertEqual(service.downloads.first?.revision, "rev1")
        XCTAssertNil(opener.error)
    }
    func testPreviewPrecedesEnhancementAndBackgroundResumesLocally() async throws {
        let service = MockDropbox(); let file = entry(); service.files[file.id] = file
        // iOS grants no background time here, so recognition pauses immediately.
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(delay: 80_000_000), backgroundTime: ManualBackgroundTime(grants: false))
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.displayed != nil && opener.recognizing }
        XCTAssertEqual(opener.displayed?.url.lastPathComponent.hasPrefix("preview"), true)
        let preview = opener.displayed?.url
        opener.background()
        XCTAssertEqual(opener.displayed?.url, preview); XCTAssertFalse(opener.recognizing)
        opener.foreground()
        try await eventually { opener.status == nil && opener.displayed?.url.lastPathComponent.hasPrefix("searchable") == true }
        XCTAssertEqual(service.downloads.count, 1, "Foreground enhancement must not check or download Dropbox again")
        XCTAssertNil(opener.warning)
    }
    func testBackgroundTimeLetsRecognitionFinishAndIsReturned() async throws {
        let service = MockDropbox(); let file = entry(); service.files[file.id] = file
        let time = ManualBackgroundTime(grants: true)
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(delay: 80_000_000), backgroundTime: time)
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.displayed != nil && opener.recognizing }
        opener.background()
        XCTAssertTrue(opener.recognizing, "Recognition continues while iOS grants background time")
        XCTAssertEqual(time.active, 1)
        try await eventually { opener.displayed?.url.lastPathComponent.hasPrefix("searchable") == true && !opener.recognizing }
        XCTAssertEqual(time.active, 0, "Background time is returned as soon as recognition finishes")
        XCTAssertNil(opener.warning)
    }
    func testExpiredBackgroundTimePausesAndForegroundResumes() async throws {
        let service = MockDropbox(); let file = entry(); service.files[file.id] = file
        let time = ManualBackgroundTime(grants: true)
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(delay: 150_000_000), backgroundTime: time)
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.displayed != nil && opener.recognizing }
        opener.background()
        time.expire()
        XCTAssertFalse(opener.recognizing); XCTAssertEqual(opener.warning, DocumentOpenCoordinator.pausedWarning)
        XCTAssertEqual(time.active, 0)
        opener.foreground()
        try await eventually { opener.displayed?.url.lastPathComponent.hasPrefix("searchable") == true && opener.status == nil }
        XCTAssertNil(opener.warning)
    }
    func testDisplayNamesKindsAndRowDetails() {
        XCTAssertEqual(displayName("Meeting.note"), "Meeting")
        XCTAssertEqual(displayName("Paper.PDF.mark"), "Paper")
        XCTAssertEqual(displayName(".note"), ".note")
        var mark = entry("id:m", name: "Paper.pdf.mark", path: "/n/paper.pdf.mark"); mark.size = 1_000
        var pdf = entry("id:p", name: "Paper.pdf", path: "/n/paper.pdf"); pdf.size = 2_000
        let now = Date()
        mark.modified = now.addingTimeInterval(-3600 * 24 * 40); pdf.modified = now
        let item = LibraryItem(entry: mark, original: pdf)
        XCTAssertEqual(item.name, "Paper")
        XCTAssertTrue(item.detail.hasPrefix("Annotated PDF · \(now.formatted(date: .omitted, time: .shortened))"), item.detail)
        XCTAssertTrue(item.detail.hasSuffix(ByteCountFormatter.string(fromByteCount: 3_000, countStyle: .file)))
        XCTAssertEqual(shortModified(now.addingTimeInterval(-86_400), now: now), "Yesterday")
    }
    func testReloadFetchesCompanionOnlyChange() async throws {
        let service = MockDropbox()
        let mark = entry("id:m", name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        var pdf = entry("id:p", name: "A.pdf", path: "/notes/a.pdf")
        service.files = [mark.id: mark, pdf.id: pdf]
        service.pages = [.init(entries: [mark, pdf], cursor: "end", hasMore: false)]
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer())
        let reference = DocumentReference.remote(mark, account: "account")
        opener.openRemote(reference, service: service)
        try await eventually { opener.displayed != nil && opener.status == nil }
        pdf.revision = "changed-companion"
        service.files[pdf.id] = pdf
        service.pages = [.init(entries: [mark, pdf], cursor: "end", hasMore: false)]
        opener.openRemote(reference, service: service)
        try await eventually { service.downloads.count == 4 && opener.status == nil }
        XCTAssertEqual(service.downloads.map(\.revision), ["rev1", "rev1", "changed-companion", "rev1"])
    }
    func testOriginalPDFIsFoundByPathWithoutListingTheFolder() async throws {
        let service = MockDropbox()
        let mark = entry("id:m", name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        let pdf = entry("id:p", name: "A.pdf", path: "/notes/a.pdf")
        service.files = [mark.id: mark, pdf.id: pdf]
        let original = try await DocumentOpenCoordinator.resolveOriginal(of: mark, service: service)
        XCTAssertEqual(original.id, pdf.id)
        XCTAssertTrue(service.calls.isEmpty, "A direct path lookup must not list the folder")
        XCTAssertEqual(service.metadataRequests, ["/notes/A.pdf"])
    }
    func testOriginalLookupFallsBackToListingAndKeepsOfflineErrors() async throws {
        let service = MockDropbox()
        let mark = entry("id:m", name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        // The listing knows the original under an ID the direct path lookup cannot reach.
        let listed = RemoteEntry(id: "id:p", name: "A.pdf", path: "/notes/a.pdf", isFolder: false, revision: "rev1", size: 3)
        service.files = [mark.id: mark]
        service.pages = [.init(entries: [mark, listed], cursor: "end", hasMore: false)]
        do { _ = try await DocumentOpenCoordinator.resolveOriginal(of: mark, service: service); XCTFail("Expected missing metadata") }
        catch { XCTAssertEqual(service.calls.count, 1, "Fallback lists the folder once") }

        service.offline = true
        do { _ = try await DocumentOpenCoordinator.resolveOriginal(of: mark, service: service); XCTFail("Expected offline") }
        catch ReaderError.offline {} catch { XCTFail("Offline must not become a missing companion: \(error)") }
        XCTAssertEqual(service.calls.count, 1, "Offline must not fall back to listing")
    }
    func testDisconnectForgetsOnlyThatAccountsRecentsAndRoot() {
        let store = store()
        store.save(.remote(entry(), account: "a"), page: 1); store.save(.remote(entry("id:b"), account: "b"), page: 2)
        store.setRoot(entry("id:root", name: "Supernote"), account: "a")
        store.removeAll(account: "a")
        XCTAssertEqual(store.records.map(\.reference.accountID), ["b"])
        XCTAssertNil(store.root(account: "a"))
    }
    func testWrongRevisionNeverRenders() async throws {
        let service = MockDropbox(); let file = entry(); service.files[file.id] = file; service.wrongRevision = true
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer())
        opener.openRemote(.remote(file, account: "account"), service: service)
        try await eventually { opener.error != nil }
        XCTAssertNil(opener.displayed)
    }
    func testMissingCompanionRequiresExplicitChoice() async throws {
        let service = MockDropbox(); let file = entry(name: "A.pdf.mark", path: "/notes/a.pdf.mark")
        service.files[file.id] = file
        service.pages = [.init(entries: [entry("id:wrong", name: "A.pdf", path: "/elsewhere/a.pdf")], cursor: "end", hasMore: false)]
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer())
        let ref = DocumentReference.remote(file, account: "account")
        opener.openRemote(ref, service: service)
        try await eventually { opener.missingCompanion }
        XCTAssertTrue(service.downloads.isEmpty)
        opener.openRemote(ref, service: service, annotationsOnly: true)
        try await eventually { opener.displayed != nil && opener.status == nil }
        XCTAssertEqual(service.downloads.count, 1)
    }
    func testStaleOpenCannotReplaceNewDocument() async throws {
        let service = MockDropbox(); service.delay = 40_000_000
        let first = entry(), second = entry("id:b", name: "B.note")
        service.files = [first.id: first, second.id: second]
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer())
        opener.openRemote(.remote(first, account: "account"), service: service)
        try await Task.sleep(for: .milliseconds(10))
        opener.openRemote(.remote(second, account: "account"), service: service)
        try await eventually { opener.displayed != nil && opener.status == nil }
        XCTAssertEqual(opener.reference?.fileID, second.id)
        XCTAssertNil(opener.error)
    }
    func testSearchAndPositionAfterPDFReplacement() async throws {
        func document(_ text: String) throws -> PDFDocument {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
            let data = renderer.pdfData { ctx in
                for _ in 0..<2 { ctx.beginPage(); (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 12)]) }
            }
            return try XCTUnwrap(PDFDocument(data: data))
        }
        let reader = ReaderModel(), first = try document("old"), second = try document("new")
        reader.replace(first, page: 99)
        XCTAssertEqual(reader.page, 1)
        reader.query = "new"; reader.replace(second, page: 1)
        XCTAssertEqual(reader.query, "new"); XCTAssertTrue(reader.results.isEmpty)
        XCTAssertEqual(reader.view.document, second); XCTAssertEqual(reader.page, 1)
        let oldSelection = try XCTUnwrap(first.page(at: 0)?.selection(for: NSRange(location: 0, length: 3)))
        reader.select(oldSelection)
        XCTAssertNil(reader.view.currentSelection)
        try await eventually { reader.results.count == 2 && !reader.searching }
        XCTAssertEqual(reader.page, 1)
        reader.didMatchString(reader.results[0])
        reader.query = ""; reader.search()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(reader.results.isEmpty, "A queued callback from the previous query must not repopulate cleared search")
    }
    func testRecentsUseAccountAndIDAndExcludeImports() {
        let store = store(), a = DocumentReference.remote(entry(), account: "a"), b = DocumentReference.remote(entry(), account: "b")
        store.save(a, page: 3); store.save(b, page: 5)
        XCTAssertEqual(store.page(for: a), 3); XCTAssertEqual(store.records.count, 2)
        store.save(.init(source: .imported, accountID: nil, fileID: "local", name: "Local"), page: 8)
        XCTAssertEqual(store.records.count, 2)
    }
    func testSupernoteFoldersAreSuggestedAndRootChangesAreObservable() {
        func folder(_ id: String, _ name: String) -> RemoteEntry { .init(id: id, name: name, path: "/" + name, isFolder: true) }
        let items = LibraryItem.group([folder("id:a", "Apps"), folder("id:s", "Supernote"),
                                       entry("id:n", name: "supernote.note"), folder("id:b", "My Supernote Backup")])
        XCTAssertEqual(LibraryItem.supernoteFolders(in: items).map(\.id), ["id:b", "id:s"])
        let recents = store()
        let before = recents.rootRevision
        recents.setRoot(folder("id:s", "Supernote"), account: "a")
        XCTAssertEqual(recents.root(account: "a")?.id, "id:s")
        XCTAssertGreaterThan(recents.rootRevision, before)
        recents.removeAll(account: "a")
        XCTAssertNil(recents.root(account: "a"))
    }
}

@MainActor private final class MockOAuth: OAuthDriver {
    var hasSession = false
    var connected = false
    var callback: ((Bool, String?) -> Void)?
    func connect() { connected = true }
    func handle(_ url: URL, completion: @escaping (Bool, String?) -> Void) -> Bool { callback = completion; return true }
    func disconnect() { hasSession = false }
}
@MainActor final class OAuthTests: XCTestCase {
    func testCallbackRoutingAndSessionTransitions() {
        let driver = MockOAuth(), session = DropboxSession(key: "synthetic", driver: MockOAuth())
        XCTAssertEqual(session.state, .disconnected)
        let subject = DropboxSession(key: "synthetic", driver: driver)
        subject.connect(); XCTAssertTrue(driver.connected); XCTAssertEqual(subject.state, .connecting)
        XCTAssertFalse(subject.handle(URL(string: "file:///example.pdf")!))
        XCTAssertTrue(subject.handle(URL(string: "db-synthetic://callback")!))
        driver.hasSession = true; driver.callback?(true, nil)
        XCTAssertEqual(subject.state, .connected)
        subject.disconnect(); XCTAssertEqual(subject.state, .disconnected); XCTAssertNil(subject.accountID)
    }
    func testRememberedAccountRestoresOnlyForConnectedSession() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["id": "dbid:synthetic", "name": "Synthetic"], forKey: "mobile.dropbox.account")
        let connected = MockOAuth(); connected.hasSession = true
        let restored = DropboxSession(key: "synthetic", driver: connected, defaults: defaults)
        XCTAssertEqual(restored.accountID, "dbid:synthetic")
        XCTAssertNil(DropboxSession(key: "synthetic", driver: MockOAuth(), defaults: defaults).accountID)
        restored.disconnect()
        XCTAssertNil(defaults.object(forKey: "mobile.dropbox.account"))
    }
    func testRestoredSessionAndCancelledAuthorization() {
        let driver = MockOAuth(); driver.hasSession = true
        let subject = DropboxSession(key: "synthetic", driver: driver)
        XCTAssertEqual(subject.state, .connected)
        subject.connect(); _ = subject.handle(URL(string: "db-synthetic://callback")!)
        driver.callback?(false, "Canceled")
        XCTAssertEqual(subject.state, .disconnected); XCTAssertEqual(subject.error, "Canceled")
    }
}
