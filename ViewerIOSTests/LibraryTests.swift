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
    func list(path: String, cursor: String?) async throws -> FolderPage {
        calls.append((path, cursor)); return pages.removeFirst()
    }
    func metadata(id: String) async throws -> RemoteEntry {
        if offline { throw ReaderError.offline("Could not reach Dropbox.") }
        guard let file = files[id] else { throw ReaderError.message("File missing") }
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

private struct FakeRenderer: MobileRendering {
    var failOCR = false
    var delay: UInt64 = 0
    func render(_ inputs: LocalInputs, to: URL, recognize: Bool, token: CancellationToken,
                progress: @escaping @Sendable (String) -> Void) async throws {
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
        let opener = DocumentOpenCoordinator(recents: store(), renderer: FakeRenderer(delay: 80_000_000))
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
