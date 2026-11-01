import Foundation
import SwiftyDropbox

/// Converts SDK failures without displaying response bodies, tokens or file paths.
enum DropboxFailure {
    static let readScopes = ["files.metadata.read", "files.content.read", "account_info.read"]

    static func missingScope(in message: String?) -> String? {
        readScopes.first { message?.contains("required scope '\($0)'") == true }
    }
    private static func permission(_ scope: String?) -> ReaderError {
        let permission = readScopes.contains(scope ?? "") ? scope! : "the required read permission"
        return .message("Dropbox has not granted \(permission). Enable it in the app's Permissions tab in the Dropbox developer console and save with Submit. Then use Account → Disconnect and Connect Dropbox again.")
    }
    static func convert(_ error: CallError<Any>, now: Date = Date()) -> ReaderError {
        switch error {
        case .badInputError(let message, _):
            // Dropbox returns HTTP 400 when a scope is disabled on the registration,
            // as well as HTTP 401 when a token is missing a granted scope.
            if let scope = missingScope(in: message) { return permission(scope) }
            return .message("Dropbox rejected this request (HTTP 400). Check the Dropbox app registration and its read permissions, then retry.")
        case .authError(let error, _, _, _):
            if case .missingScope(let scope) = error { return permission(scope.requiredScope) }
            return .reconnect
        case .rateLimitError(let limit, _, _, _):
            return .rateLimited(now.addingTimeInterval(TimeInterval(limit.retryAfter)))
        case .routeError:
            return .message("Dropbox could not find or read this item. Refresh the folder and retry.")
        case .accessError:
            return .message("Dropbox denied access to this item. Check account and folder permissions, then reconnect if needed.")
        case .internalServerError, .httpError:
            return .message("Dropbox returned a server error. Wait a moment and retry.")
        case .serializationError:
            return .message("This version of the app could not read Dropbox's response. Retry; if it persists, the app needs an update.")
        case .reconnectionError:
            return .reconnect
        case .clientError(let error):
            switch error {
            case .oauthError: return .reconnect
            case .urlSessionError(let error):
                if (error as NSError).code == URLError.timedOut.rawValue {
                    return .offline("The Dropbox request timed out. Check your connection and retry.")
                }
                return .offline("Could not reach Dropbox. Check your internet connection and retry.")
            case .fileAccessError:
                return .message("Could not save the Dropbox download. Check available storage and retry.")
            case .requestObjectDeallocated, .unexpectedState, .other:
                return .message("The Dropbox SDK could not complete the request. Retry; if it persists, the app needs an update.")
            }
        }
    }
}
