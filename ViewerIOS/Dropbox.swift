import Foundation
import Observation
import UIKit
import SwiftyDropbox

@MainActor protocol OAuthDriver {
    var hasSession: Bool { get }
    func connect()
    func handle(_ url: URL, completion: @escaping (Bool, String?) -> Void) -> Bool
    func disconnect()
}

@MainActor final class SDKOAuthDriver: OAuthDriver {
    static var configured = false
    init(key: String) {
        if !Self.configured { DropboxClientsManager.setupWithAppKey(key); Self.configured = true }
    }
    var hasSession: Bool { DropboxClientsManager.authorizedClient != nil }
    func connect() {
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController
        var controller = root
        while let presented = controller?.presentedViewController { controller = presented }
        DropboxClientsManager.authorizeFromControllerV2(UIApplication.shared, controller: controller,
            loadingStatusDelegate: nil, openURL: { UIApplication.shared.open($0) },
            scopeRequest: ScopeRequest(scopeType: .user, scopes: DropboxFailure.readScopes, includeGrantedScopes: false))
    }
    func handle(_ url: URL, completion: @escaping (Bool, String?) -> Void) -> Bool {
        DropboxClientsManager.handleRedirectURL(url, includeBackgroundClient: false) { result in
            Task { @MainActor in
                switch result {
                case .success: completion(true, nil)
                case .cancel: completion(false, "Dropbox connection was canceled.")
                case .error: completion(false, "Dropbox authorization failed. Try connecting again.")
                case nil: break
                }
            }
        }
    }
    func disconnect() { DropboxClientsManager.unlinkClients() }
}

@Observable @MainActor final class DropboxSession {
    enum State: Equatable { case unconfigured, disconnected, connecting, connected }
    var state: State
    var accountID: String?
    var accountName: String?
    var error: String?
    private let driver: (any OAuthDriver)?
    private let key: String
    init(key: String = Bundle.main.object(forInfoDictionaryKey: "DropboxAppKey") as? String ?? "unconfigured",
         driver: (any OAuthDriver)? = nil) {
        self.key = key
        self.driver = driver ?? (key != "unconfigured" && !key.isEmpty ? SDKOAuthDriver(key: key) : nil)
        state = self.driver == nil ? .unconfigured : self.driver!.hasSession ? .connected : .disconnected
    }
    func connect() { error = nil; guard let driver else { return }; state = .connecting; driver.connect() }
    @discardableResult func handle(_ url: URL) -> Bool {
        guard url.scheme == "db-\(key)", let driver else { return false }
        return driver.handle(url) { [weak self] success, error in
            self?.state = success ? .connected : .disconnected
            self?.error = error
            if success { Task { await self?.loadAccount() } }
        }
    }
    func loadAccount() async {
        guard state == .connected, let client = DropboxClientsManager.authorizedClient else { return }
        do {
            let account = try await client.users.getCurrentAccount().response()
            guard state == .connected else { return }
            accountID = account.accountId; accountName = account.name.displayName
        } catch let error as CallError<Void> {
            self.error = DropboxFailure.convert(error.typeErased).localizedDescription
        } catch { self.error = "Could not read Dropbox account. Reconnect or retry when online." }
    }
    func disconnect() { driver?.disconnect(); state = .disconnected; accountID = nil; accountName = nil; error = nil }
    func resumeAuthorization() { if state == .connecting, driver?.hasSession == true { state = .connected } }
}

@MainActor final class SDKDropboxService: DropboxService {
    private var retryAfter = Date.distantPast
    private let onFailure: ((CallError<Any>) -> Void)?
    init(onFailure: ((CallError<Any>) -> Void)? = nil) { self.onFailure = onFailure }
    private func client() throws -> DropboxClient {
        if Date() < retryAfter { throw ReaderError.rateLimited(retryAfter) }
        guard let client = DropboxClientsManager.authorizedClient else { throw ReaderError.reconnect }
        return client
    }
    private func response<R: HasRequestResponse>(_ request: R, cancel: @escaping @Sendable () -> Void) async throws -> R.ValueType {
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let value = try await request.response()
                try Task.checkCancellation()
                return value
            } onCancel: { cancel() }
        } catch let error as CallError<R.ESerial.ValueType> {
            if Task.isCancelled { throw CancellationError() }
            onFailure?(error.typeErased)
            let failure = DropboxFailure.convert(error.typeErased)
            if case .rateLimited(let date) = failure { retryAfter = date }
            throw failure
        }
    }
    static func entry(_ metadata: Files.Metadata) -> RemoteEntry? {
        if let file = metadata as? Files.FileMetadata {
            return .init(id: file.id, name: file.name, path: file.pathLower ?? "", isFolder: false, revision: file.rev, size: file.size)
        }
        if let folder = metadata as? Files.FolderMetadata {
            return .init(id: folder.id, name: folder.name, path: folder.pathLower ?? "", isFolder: true)
        }
        return nil
    }
    func list(path: String, cursor: String?) async throws -> FolderPage {
        let client = try client()
        let result: Files.ListFolderResult
        if let cursor {
            let request = client.files.listFolderContinue(cursor: cursor)
            result = try await response(request, cancel: { request.cancel() })
        } else {
            let request = client.files.listFolder(path: path, recursive: false)
            result = try await response(request, cancel: { request.cancel() })
        }
        return .init(entries: result.entries.compactMap(Self.entry), cursor: result.cursor, hasMore: result.hasMore)
    }
    func metadata(id: String) async throws -> RemoteEntry {
        let request = try client().files.getMetadata(path: id)
        let value = try await response(request, cancel: { request.cancel() })
        guard let entry = Self.entry(value), !entry.isFolder else { throw ReaderError.message("This document is missing or is now a folder.") }
        return entry
    }
    func download(_ entry: RemoteEntry, to destination: URL, progress: @escaping (Double) -> Void) async throws -> RemoteEntry {
        guard let revision = entry.revision else { throw ReaderError.message("Dropbox did not return a file revision. Refresh and retry.") }
        let request = try client().files.download(path: "rev:\(revision)", overwrite: false, destination: destination)
        request.progress { value in progress(value.fractionCompleted) }
        let result = try await response(request, cancel: { request.cancel() })
        guard let downloaded = Self.entry(result.0) else { throw ReaderError.message("Invalid Dropbox download metadata.") }
        return downloaded
    }
}
