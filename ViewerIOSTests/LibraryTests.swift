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
    func testBookmarkOpensAtItsPageAndRefreshesMetadata() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let favorites = FavoriteDocumentsStore(defaults: defaults)
        let recents = RecentDocumentsStore(defaults: defaults)
        let old = DocumentReference.remote(entry(), account: "a")
        recents.save(old, page: 3)
        favorites.toggleBookmark(old, page: 12, title: "Pancakes")
        let renamed = entry(name: "Renamed.note", path: "/moved/renamed.note")
        let service = MockDropbox(); service.files[renamed.id] = renamed
        let opener = DocumentOpenCoordinator(recents: recents, renderer: FakeRenderer())
        opener.favorites = favorites
        opener.openRemote(old, service: service, page: 12)
        XCTAssertEqual(opener.page, 12, "A bookmark overrides the last reading position")
        try await eventually { opener.displayed != nil && opener.status == nil }
        XCTAssertEqual(favorites.records.first?.reference.name, "Renamed.note")
        XCTAssertEqual(favorites.records.first?.reference.path, "/moved/renamed.note")
        XCTAssertEqual(favorites.records.first?.bookmarkedPage, 12, "Reading does not move a bookmark")
        opener.openRemote(old, service: service)
        XCTAssertEqual(opener.page, recents.page(for: old), "Without a bookmark the reading position is used")
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
        reader.findActive = true
        reader.replace(first, page: 99)
        XCTAssertEqual(reader.page, 1)
        reader.query = "new"; reader.replace(second, page: 1)
        XCTAssertEqual(reader.query, "new"); XCTAssertTrue(reader.results.isEmpty)
        XCTAssertEqual(reader.view.document, second); XCTAssertEqual(reader.page, 1)
        let oldSelection = try XCTUnwrap(first.page(at: 0)?.selection(for: NSRange(location: 0, length: 3)))
        reader.didMatchString(oldSelection)
        try await eventually { reader.results.count == 2 && !reader.searching }
        XCTAssertTrue(reader.results.allSatisfy { $0.pages.allSatisfy { $0.document === second } }, "Matches from the old document are dropped")
        reader.didMatchString(reader.results[0])
        reader.query = ""; reader.search()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(reader.results.isEmpty, "A queued callback from the previous query must not repopulate cleared search")
    }
    private func pages(_ texts: [String]) throws -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let data = renderer.pdfData { ctx in
            for text in texts { ctx.beginPage(); (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 12)]) }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }
    func testFindStepsThroughMatchesAndWraps() async throws {
        let reader = ReaderModel()
        reader.replace(try pages(["soup", "bread", "soup", "soup"]), page: 0)
        reader.findActive = true
        reader.query = "soup"; reader.search()
        try await eventually { reader.results.count == 3 && !reader.searching }
        XCTAssertEqual(reader.current, 0, "Typing selects the first match")
        XCTAssertEqual(reader.currentMatchPage, 0)
        reader.next(); XCTAssertEqual(reader.currentMatchPage, 2)
        reader.next(); reader.next()
        XCTAssertEqual(reader.current, 0, "Next wraps from the last match to the first")
        reader.previous(); XCTAssertEqual(reader.current, 2, "Previous wraps from the first match to the last")
        reader.endFind()
        XCTAssertTrue(reader.results.isEmpty); XCTAssertNil(reader.current); XCTAssertEqual(reader.query, "soup")
    }
    /// Opening another document removes the reader's PDF view while it loads and puts it back when
    /// the PDF arrives, so the requested page is set before the view is laid out again.
    func testOtherDocumentOpensAtRequestedPageAfterViewReturns() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let reader = ReaderModel()
        var reported: [Int] = []
        reader.pageChanged = { reported.append($0) }
        reader.view.frame = window.bounds; window.addSubview(reader.view); window.isHidden = false
        defer { window.isHidden = true }
        reader.replace(try pages(["a", "b"]), page: 0)
        reader.view.layoutIfNeeded()
        // The reader shows a progress view while the next document loads.
        // SwiftUI inserts it again without a size, and sizes it only after the new PDF is set.
        reader.view.removeFromSuperview(); reader.view.frame = .zero
        reader.reset()
        reader.replace(try pages(["1", "2", "3", "4", "5", "6"]), page: 4)
        window.addSubview(reader.view)
        reader.view.frame = window.bounds
        reader.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let document = try XCTUnwrap(reader.document), current = try XCTUnwrap(reader.view.currentPage)
        XCTAssertEqual(document.index(for: current), 4, "The view shows the requested page")
        XCTAssertEqual(reader.page, 4); XCTAssertEqual(reported.last, 4, "No stale first-page report overwrites the position")
    }
    func testMatchIsCenteredAboveTheFindBar() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 1200)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for text in ["bread", "soup", "bread"] {
                ctx.beginPage(); (text as NSString).draw(at: CGPoint(x: 40, y: 900), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let reader = ReaderModel()
        reader.view.frame = window.bounds; window.addSubview(reader.view); window.isHidden = false
        defer { window.isHidden = true }
        reader.replace(try XCTUnwrap(PDFDocument(data: data)), page: 0)
        reader.view.layoutIfNeeded()
        reader.findBarTop = 600
        reader.findActive = true
        reader.query = "soup"; reader.search()
        try await eventually { reader.results.count == 1 && !reader.searching }
        let match = reader.results[0], page = try XCTUnwrap(match.pages.first)
        let visible = reader.view.convert(match.bounds(for: page), from: page)
        XCTAssertEqual(visible.midY, 300, accuracy: 30, "The match sits in the middle of the area above the find bar")
    }
    func testClosedFindNeverSearches() async throws {
        let reader = ReaderModel()
        reader.query = "soup"
        reader.replace(try pages(["soup"]), page: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(reader.results.isEmpty, "A reloaded document must not jump to a match while find is closed")
        XCTAssertFalse(reader.searching)
    }
    func testFindResumesAtItsPageAfterRecognizedPDFReplacesPreview() async throws {
        let reader = ReaderModel()
        reader.replace(try pages(["soup", "soup", "bread", "soup"]), page: 0)
        reader.findActive = true
        reader.query = "soup"; reader.search()
        try await eventually { reader.results.count == 3 && !reader.searching }
        reader.next(); reader.next()
        XCTAssertEqual(reader.currentMatchPage, 3)
        reader.replace(try pages(["soup", "soup", "bread", "soup"]), page: 3)
        try await eventually { reader.results.count == 3 && !reader.searching }
        XCTAssertEqual(reader.current, 2, "Find stays on the match it was on, not the first one")
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

@MainActor final class FavoriteDocumentsTests: XCTestCase {
    private func reference(_ id: String, account: String = "a", name: String = "Note.note") -> DocumentReference {
        .remote(.init(id: id, name: name, path: "/" + name, isFolder: false), account: account)
    }
    func testPersistenceIdentityAndMetadata() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = FavoriteDocumentsStore(defaults: defaults)
        let first = reference("1")
        store.toggleDocument(first)
        store.toggleBookmark(first, page: 4, title: "Soup")
        let renamed = reference("1", name: "Renamed.note")
        store.update(renamed)
        let restored = FavoriteDocumentsStore(defaults: defaults)
        XCTAssertEqual(restored.records.count, 2)
        XCTAssertTrue(restored.isDocumentFavorite(first))
        XCTAssertTrue(restored.isBookmarked(first, page: 4))
        XCTAssertFalse(restored.isBookmarked(first, page: 5))
        XCTAssertEqual(restored.records.map(\.reference.name), ["Renamed.note", "Renamed.note"])
        XCTAssertEqual(restored.records.last?.title, "Soup")
        restored.toggleDocument(renamed)
        XCTAssertFalse(restored.isDocumentFavorite(first))
        XCTAssertTrue(restored.isFavorite(first), "A bookmark still marks the document as a favorite")
        restored.toggleBookmark(renamed, page: 4, title: nil)
        XCTAssertTrue(restored.records.isEmpty)
    }
    func testSeveralBookmarksPerDocument() {
        let store = FavoriteDocumentsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let note = reference("1")
        store.toggleBookmark(note, page: 2, title: "Pancakes")
        store.toggleBookmark(note, page: 9, title: nil)
        XCTAssertEqual(store.bookmarkedPages(note), [2, 9])
        XCTAssertEqual(Set(store.records.map(\.id)).count, 2)
        store.remove(store.records[0])
        XCTAssertEqual(store.bookmarkedPages(note), [9])
    }
    func testRecordsFromBeforeBookmarksBecomeDocumentFavorites() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let legacy = [["reference": ["source": "dropbox", "accountID": "a", "fileID": "1", "name": "Old.note"], "page": 7]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "mobile.favorites")
        let store = FavoriteDocumentsStore(defaults: defaults)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertNil(store.records.first?.bookmarkedPage, "The old saved page was a reading position, not a bookmark")
        XCTAssertTrue(store.isDocumentFavorite(.init(source: .dropbox, accountID: "a", fileID: "1", name: "Old.note")))
    }
    func testRefreshTitlesLabelsBookmarksOnly() {
        let store = FavoriteDocumentsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let note = reference("1"), other = reference("2")
        store.toggleDocument(note)
        store.toggleBookmark(note, page: 3, title: nil)
        store.toggleBookmark(other, page: 3, title: "Keep")
        store.refreshTitles(note) { $0 == 3 ? "Lasagne" : nil }
        XCTAssertEqual(store.records.map(\.title), [nil, "Lasagne", "Keep"])
    }
    func testTitleForPageUsesOwnThenEarlierTitle() {
        let titles = [ReaderModel.Title(label: "Breakfast", page: 1, depth: 0),
                      ReaderModel.Title(label: "Pancakes", page: 1, depth: 1),
                      ReaderModel.Title(label: "Dinner", page: 4, depth: 0)]
        XCTAssertNil(ReaderModel.title(forPage: 0, in: titles))
        XCTAssertEqual(ReaderModel.title(forPage: 1, in: titles), "Breakfast")
        XCTAssertEqual(ReaderModel.title(forPage: 3, in: titles), "Pancakes", "A recipe running onto later pages keeps its name")
        XCTAssertEqual(ReaderModel.title(forPage: 6, in: titles), "Dinner")
    }
    func testAccountOrderingCleanupAndImportExclusion() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = FavoriteDocumentsStore(defaults: defaults)
        let a = reference("1"), other = reference("1", account: "b"), c = reference("3")
        store.toggleDocument(a); store.toggleDocument(other); store.toggleDocument(c)
        store.move(from: IndexSet(integer: 1), to: 0, account: "a")
        XCTAssertEqual(store.records.filter { $0.reference.accountID == "a" }.map(\.id), [c.id, a.id])
        store.toggleDocument(.init(source: .imported, accountID: nil, fileID: "local", name: "Local.pdf"))
        XCTAssertEqual(store.records.count, 3)
        store.removeAll(account: "a")
        XCTAssertEqual(FavoriteDocumentsStore(defaults: defaults).records.map(\.id), [other.id])
    }
}

final class PageThumbnailRendererTests: XCTestCase {
    func testRendersAndCachesPagesOfTheDisplayedPDF() async throws {
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples")
        let pdf = examples.appendingPathComponent("2026-03-22 Garmin Connect Integration.pdf")
        let renderer = PageThumbnailRenderer()
        let rendered = await renderer.image(0, in: pdf)
        let image = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(image.size.width, 100)
        let cached = await renderer.image(0, in: pdf)
        XCTAssertTrue(cached === image, "A page renders once per file")
        let missing = await renderer.image(0, in: examples.appendingPathComponent("missing.pdf"))
        XCTAssertNil(missing)
    }
}
