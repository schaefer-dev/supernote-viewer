import XCTest
import SwiftyDropbox
@testable import SupernoteViewerIOS

final class DropboxFailureTests: XCTestCase {
    func testDisabledRegistrationReadScopesExplainConsoleFix() {
        for scope in ["files.metadata.read", "files.content.read", "account_info.read"] {
            let body = "Your app (ID: 123) is not permitted to access this endpoint because it does not have the required scope '\(scope)'."
            let error = DropboxFailure.convert(.badInputError(body, "synthetic-request-id"))
            XCTAssertTrue(error.localizedDescription.contains(scope))
            XCTAssertTrue(error.localizedDescription.contains("Submit"))
            XCTAssertTrue(error.localizedDescription.contains("Disconnect"))
            XCTAssertFalse(error.localizedDescription.contains("storage"))
        }
    }
    func testTokenMissingScopeExplainsReauthorization() {
        let error = DropboxFailure.convert(.authError(.missingScope(.init(requiredScope: "files.metadata.read")), nil, nil, nil))
        XCTAssertTrue(error.localizedDescription.contains("files.metadata.read"))
        XCTAssertTrue(error.localizedDescription.contains("Connect Dropbox again"))
    }
    func testServerBodiesAreNotDisplayedAndFailuresStayDistinct() {
        let marker = "synthetic-sensitive-response-body"
        let badInput = DropboxFailure.convert(.badInputError(marker, nil)).localizedDescription
        XCTAssertTrue(badInput.contains("HTTP 400")); XCTAssertFalse(badInput.contains(marker))
        let network = DropboxFailure.convert(.clientError(.urlSessionError(URLError(.notConnectedToInternet)))).localizedDescription
        XCTAssertTrue(network.contains("internet")); XCTAssertFalse(network.contains("storage"))
        let storage = DropboxFailure.convert(.clientError(.fileAccessError(CocoaError(.fileWriteOutOfSpace)))).localizedDescription
        XCTAssertTrue(storage.contains("storage"))
        let decoding = DropboxFailure.convert(.serializationError(NSError(domain: marker, code: 1))).localizedDescription
        XCTAssertTrue(decoding.contains("response")); XCTAssertFalse(decoding.contains(marker))
    }
    func testRateLimitKeepsServerRetryFloor() {
        let now = Date(timeIntervalSince1970: 100)
        let error = DropboxFailure.convert(.rateLimitError(.init(reason: .tooManyRequests, retryAfter: 30), nil, nil, nil), now: now)
        guard case .rateLimited(let date) = error else { return XCTFail("Expected a rate limit") }
        XCTAssertEqual(date, now.addingTimeInterval(30))
    }
}
