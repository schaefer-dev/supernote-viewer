#if DEBUG
import Foundation
import SwiftyDropbox

/// Explicit developer launch diagnostic. Records only error categories/codes and counts,
/// never tokens, account identifiers, paths or filenames.
@MainActor enum DropboxDiagnostics {
    static func failure(_ error: CallError<Any>) -> String {
        switch error {
        case .clientError(let client):
            switch client {
            case .urlSessionError(let error): return "network:\((error as NSError).code)"
            case .fileAccessError(let error): return "file:\((error as NSError).code)"
            case .oauthError: return "client:oauth"
            case .requestObjectDeallocated: return "client:requestObjectDeallocated"
            case .unexpectedState: return "client:unexpectedState"
            case .other: return "client:other"
            }
        case .authError(let error, _, _, _):
            if case .missingScope = error { return "auth:missingScope" }
            return "auth"
        case .badInputError(let message, _):
            return "badInput:400:" + (DropboxFailure.missingScope(in: message) ?? "other")
        case .accessError: return "access:403"
        case .serializationError: return "serialization"
        case .reconnectionError: return "reconnection"
        case .httpError(let code, _, _): return "http:\(code ?? 0)"
        case .internalServerError(let code, _, _): return "server:\(code)"
        case .routeError: return "route:409"
        case .rateLimitError: return "rateLimit:429"
        }
    }
    static func run() async {
        var report: [String: String] = [:]
        if let client = DropboxClientsManager.authorizedClient {
            do {
                let request = client.files.listFolder(path: "", recursive: false)
                let result = try await request.response()
                report["directSDK"] = "success:\(result.entries.count)"
            } catch let error as CallError<Files.ListFolderError> { report["directSDK"] = failure(error.typeErased) }
            catch { report["directSDK"] = "unexpected" }
            let service = SDKDropboxService(onFailure: { report["serviceError"] = failure($0) })
            do { report["service"] = "success:\(try await allEntries(service: service, path: "").count)" }
            catch { report["service"] = "failed" }
        } else { report["session"] = "absent" }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DropboxDiagnostic.json")
        if let data = try? JSONEncoder().encode(report) { try? data.write(to: output, options: .atomic) }
    }
}
#endif
