import SwiftUI
import UniformTypeIdentifiers

@main struct SupernoteViewerIOSApp: App {
    @State private var library = MobileLibrary()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .onOpenURL { url in
                    if !library.session.handle(url), url.isFileURL { library.importFiles([url]) }
                }
                .task {
                    await library.session.loadAccount()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--diagnose-dropbox") { await DropboxDiagnostics.run() }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { library.opener.savePosition(); library.opener.background() }
                    if phase == .active { library.session.resumeAuthorization(); library.opener.foreground() }
                }
        }
    }
}

@Observable @MainActor final class MobileLibrary {
    let session = DropboxSession()
    let service: any DropboxService = SDKDropboxService()
    let recents = RecentDocumentsStore()
    let opener: DocumentOpenCoordinator
    let reader = ReaderModel()
    let sync: LibrarySync
    let thumbnails = ThumbnailStore(cache: .shared)
    /// The Dropbox list is browsing from the root to pick a new library folder.
    var choosingRoot = false
    /// Advances whenever a rendering is saved or removed, so offline badges refresh.
    private(set) var savedGeneration = 0
    var pendingImport: URL?
    var importedWorkspace: Workspace?
    var importError: String?
    init() {
        Workspace.cleanAbandoned()
        RenderedPDFCache.shared.adoptLegacyRenderings()
        opener = DocumentOpenCoordinator(recents: recents, cache: .shared)
        // Sync renders on its own lower-priority queue so opening a document never waits behind it.
        sync = LibrarySync(cache: .shared,
                           renderer: EngineRenderer(queue: DispatchQueue(label: "SupernoteLibrarySync", qos: .utility)),
                           scheduler: SystemContinuedProcessing())
        reader.pageChanged = { [weak self] page in self?.pageChanged(page) }
        opener.renderingSaved = { [weak self] key in self?.renderingSaved(key) }
        sync.renderingSaved = { [weak self] key in self?.renderingSaved(key) }
        sync.readerIsBusy = { [weak self] in self?.opener.status != nil && self?.opener.displayed == nil }
    }
    static var exampleURLs: [URL] {
        let root = Bundle.main.resourceURL!.appendingPathComponent("examples")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "note" || $0.pathExtension == "mark" || ($0.pathExtension == "pdf" && !files.contains(URL(fileURLWithPath: $0.path + ".mark"))) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func openExample(_ url: URL) {
        let companion = url.pathExtension == "mark" ? url.deletingPathExtension() : nil
        opener.openLocal(.init(source: .example, accountID: nil, fileID: url.lastPathComponent, name: url.lastPathComponent), source: url, companion: companion)
    }
    /// Disconnecting removes the account's recents, library folder and saved renderings.
    func disconnect() {
        opener.cancel(); sync.cancel(); sync.dismiss()
        if let account = session.accountID {
            RenderedPDFCache.shared.removeAll(accountID: account)
            recents.removeAll(account: account)
        }
        thumbnails.removeAll(); savedGeneration += 1
        session.disconnect()
    }
    func removeDownloads() {
        sync.cancel(); sync.dismiss()
        RenderedPDFCache.shared.removeEverything()
        thumbnails.removeAll(); savedGeneration += 1
    }
    func startSyncCheck() {
        guard let account = session.accountID else { return }
        Task { await sync.check(service: service, account: account, root: recents.root(account: account)) }
    }
    private func renderingSaved(_ key: RenderCacheKey) {
        thumbnails.invalidate(account: key.accountID, fileID: key.fileID)
        savedGeneration += 1
    }
    @ObservationIgnored private var positionSave: Task<Void, Never>?
    /// Scrolling changes pages rapidly; persist the position once it settles. Opening another
    /// document and backgrounding save immediately.
    private func pageChanged(_ page: Int) {
        opener.page = page
        positionSave?.cancel()
        positionSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.opener.savePosition()
        }
    }
    func openRemote(_ entry: RemoteEntry, annotationsOnly: Bool = false) {
        guard let account = session.accountID else { importError = "Connect Dropbox and load your account before opening a file."; return }
        opener.openRemote(.remote(entry, account: account), service: service, annotationsOnly: annotationsOnly)
    }
    func openRecent(_ recent: RecentDocument) {
        if recent.reference.source == .example {
            if let url = Self.exampleURLs.first(where: { $0.lastPathComponent == recent.reference.fileID }) { openExample(url) }
        } else {
            guard session.accountID == recent.reference.accountID else { importError = "Connect the Dropbox account used for this recent document."; return }
            opener.openRemote(recent.reference, service: service)
        }
    }
    func reload(annotationsOnly: Bool = false) {
        guard let reference = opener.reference else { return }
        if reference.source == .dropbox {
            guard reference.accountID == session.accountID else { importError = "Reconnect the document's Dropbox account."; return }
            opener.openRemote(reference, service: service, annotationsOnly: annotationsOnly)
        } else { opener.reloadLocal(annotationsOnly: annotationsOnly) }
    }
    func importFiles(_ urls: [URL]) {
        do {
            if let pendingImport {
                guard let companion = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { throw ReaderError.message("Choose the original PDF.") }
                openImport(pendingImport, companion: companion)
                self.pendingImport = nil
                return
            }
            guard let source = urls.first(where: { $0.pathExtension.lowercased() == "mark" }) ?? urls.first else { return }
            let companion = urls.first { $0.pathExtension.lowercased() == "pdf" && $0.lastPathComponent.lowercased() == source.deletingPathExtension().lastPathComponent.lowercased() }
            if source.pathExtension.lowercased() == "mark" && companion == nil {
                let workspace = try Workspace()
                pendingImport = try DocumentOpenCoordinator.copyAuthorized(source, to: workspace.url.appendingPathComponent(source.lastPathComponent))
                importedWorkspace = workspace
            } else { openImport(source, companion: companion) }
        } catch { importError = error.localizedDescription }
    }
    func openImport(_ source: URL, companion: URL?, annotationsOnly: Bool = false) {
        opener.openLocal(.init(source: .imported, accountID: nil, fileID: UUID().uuidString, name: source.lastPathComponent), source: source, companion: companion, annotationsOnly: annotationsOnly)
    }
}
