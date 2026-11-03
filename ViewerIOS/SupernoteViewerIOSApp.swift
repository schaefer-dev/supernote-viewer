import SwiftUI
import UniformTypeIdentifiers
import Network

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
                    #if DEBUG
                    library.openUITestFixtureIfRequested()
                    #endif
                    await library.session.loadAccount()
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--diagnose-dropbox") { await DropboxDiagnostics.run() }
                    #endif
                    await library.autoSyncIfEnabled()
                }
                .onChange(of: scenePhase) { _, phase in
                    library.sync.inForeground = phase == .active
                    if phase == .background { library.opener.savePosition(); library.opener.background() }
                    if phase == .active {
                        library.session.resumeAuthorization(); library.opener.foreground()
                        Task { await library.autoSyncIfEnabled() }
                    }
                }
        }
    }
}

@Observable @MainActor final class MobileLibrary {
    let session = DropboxSession()
    let service: any DropboxService = SDKDropboxService()
    private static var libraryDefaults: UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-favorites") {
            return UserDefaults(suiteName: "favorites-ui-tests")!
        }
        #endif
        return .standard
    }
    let recents = RecentDocumentsStore(defaults: MobileLibrary.libraryDefaults)
    let favorites = FavoriteDocumentsStore(defaults: MobileLibrary.libraryDefaults)
    var accountFavorites: [FavoriteDocument] { favorites.records.filter { $0.reference.accountID == session.accountID } }
    /// Stars or unstars the page currently shown in the reader.
    func toggleBookmark() {
        guard let reference = opener.reference, opener.displayed != nil else { return }
        let page = reader.page
        favorites.toggleBookmark(reference, page: page, title: reader.title(forPage: page))
    }
    func open(_ favorite: FavoriteDocument) { openStored(favorite.reference, page: favorite.bookmarkedPage) }
    let opener: DocumentOpenCoordinator
    let reader = ReaderModel()
    let sync: LibrarySync
    let thumbnails = ThumbnailStore(cache: .shared)
    /// The connected account's Supernote folder. Choosing it is required after connecting Dropbox;
    /// browsing and Sync All start there.
    var libraryRoot: RemoteEntry? { session.accountID.flatMap { recents.root(account: $0) } }
    var needsLibraryFolder: Bool { session.state == .connected && session.accountID != nil && libraryRoot == nil }
    func chooseLibraryFolder(_ folder: RemoteEntry) {
        guard let account = session.accountID else { return }
        let first = libraryRoot == nil
        recents.setRoot(folder, account: account)
        path = []
        // After the first choice, have the review card ready on Home.
        if first { startSyncCheck() }
    }
    /// Advances whenever a rendering is saved or removed, so offline badges refresh.
    private(set) var savedGeneration = 0
    var pendingImport: URL?
    var importedWorkspace: Workspace?
    var importError: String?
    init() {
        Workspace.cleanAbandoned()
        RenderedPDFCache.shared.adoptLegacyRenderings()
        opener = DocumentOpenCoordinator(recents: recents, cache: .shared)
        opener.favorites = favorites
        // Sync renders on its own queues so opening a document never waits behind it:
        // user-initiated while the app is open, utility once it is in the background.
        sync = LibrarySync(cache: .shared,
                           renderer: EngineRenderer(queue: DispatchQueue(label: "SupernoteLibrarySync", qos: .userInitiated)),
                           backgroundRenderer: EngineRenderer(queue: DispatchQueue(label: "SupernoteLibrarySyncBackground", qos: .utility)),
                           scheduler: SystemContinuedProcessing())
        reader.pageChanged = { [weak self] page in self?.pageChanged(page) }
        reader.titlesChanged = { [weak self] in
            guard let self, let reference = opener.reference else { return }
            favorites.refreshTitles(reference) { self.reader.title(forPage: $0) }
        }
        opener.renderingSaved = { [weak self] key in self?.renderingSaved(key) }
        sync.renderingSaved = { [weak self] key in self?.renderingSaved(key) }
        sync.readerIsBusy = { [weak self] in self?.opener.status != nil && self?.opener.displayed == nil }
    }
    /// The library column's navigation: Home, then Browse Dropbox and its folders.
    var path: [LibraryRoute] = []
    #if DEBUG
    /// UI tests pass `--ui-test-open <absolute path>` to open a repository fixture; the app bundles no samples.
    private static var uiTestFixture: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-test-open"), arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        // Physical-device tests transfer fixtures into the app's Documents directory.
        if !path.hasPrefix("/") {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path)
    }
    func openUITestFixtureIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-favorites") {
            session.accountID = "ui-favorites"
            favorites.removeAll(account: "ui-favorites")
            recents.removeAll(account: "ui-favorites")
            if ProcessInfo.processInfo.arguments.contains("--ui-test-page-favorites") {
                // Bookmarks on later pages of two different documents.
                for (index, page) in [(1, 2), (2, 1)] {
                    favorites.toggleBookmark(.init(source: .dropbox, accountID: "ui-favorites", fileID: "ui-favorite-\(index)", name: "Document \(index).pdf"), page: page, title: nil)
                }
                return
            }
            for index in 1...6 {
                favorites.toggleDocument(.init(source: .dropbox, accountID: "ui-favorites", fileID: "ui-favorite-\(index)", name: "Document \(index).note"))
            }
            return
        }
        guard let url = Self.uiTestFixture else { return }
        openFixture(url)
    }
    private func openFixture(_ url: URL) {
        let companion = url.pathExtension == "mark" ? url.deletingPathExtension() : nil
        opener.openLocal(.init(source: .fixture, accountID: nil, fileID: url.path, name: url.lastPathComponent), source: url, companion: companion)
    }
    #endif
    /// Disconnecting removes the account's recents, library folder and saved renderings.
    func disconnect() {
        opener.cancel(); sync.cancel(); sync.dismiss()
        if let account = session.accountID {
            RenderedPDFCache.shared.removeAll(accountID: account)
            recents.removeAll(account: account)
            favorites.removeAll(account: account)
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
        guard let account = session.accountID, let root = libraryRoot else { return }
        Task { await sync.check(service: service, account: account, root: root) }
    }
    @ObservationIgnored private var lastAutoSync: Date?
    /// Runs Sync All without asking when the user enabled it in Settings: at launch, and when the app
    /// returns to the foreground after a while. A manual Sync All still shows the review card first.
    func autoSyncIfEnabled(now: Date = Date()) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AutoSyncSettings.enabledKey), let account = session.accountID, let root = libraryRoot,
              session.state == .connected, !sync.isActive, sync.phase != .ready else { return }
        if let lastAutoSync, now.timeIntervalSince(lastAutoSync) < AutoSyncSettings.minimumInterval { return }
        lastAutoSync = now
        let wifiOnly = defaults.object(forKey: AutoSyncSettings.wifiOnlyKey) as? Bool ?? true
        if wifiOnly, await !AutoSyncSettings.onUnmeteredNetwork() { return }
        await sync.check(service: service, account: account, root: root)
        if sync.phase == .ready { sync.start(service: service) }
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
        #if DEBUG
        if recent.reference.source == .fixture { openFixture(URL(fileURLWithPath: recent.reference.fileID)); return }
        #endif
        openStored(recent.reference)
    }
    func openStored(_ reference: DocumentReference, page: Int? = nil) {
        // A bookmark in the document already on screen just turns to its page.
        if let page, opener.reference?.id == reference.id, opener.displayed != nil, opener.status == nil {
            reader.go(to: page); return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-favorites"), reference.accountID == "ui-favorites", let url = Self.uiTestFixture {
            opener.openLocal(reference, source: url, companion: nil, page: page)
            return
        }
        #endif
        guard reference.source == .dropbox else { return }
        guard session.accountID == reference.accountID else { importError = "Connect the Dropbox account used for this document."; return }
        opener.openRemote(reference, service: service, page: page)
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

enum FavoriteThumbnailSettings {
    /// When true (the default), page favorites preview their bookmarked page instead of the first page.
    static let bookmarkedPageKey = "mobile.favoriteThumbnailShowsBookmarkedPage"
}

enum AutoSyncSettings {
    static let enabledKey = "mobile.autoSync"
    static let wifiOnlyKey = "mobile.autoSyncWiFiOnly"
    /// Returning to the app sooner than this does not start another automatic sync.
    static let minimumInterval: TimeInterval = 15 * 60
    /// True on Wi-Fi or wired networks; false on cellular, personal hotspots and when offline.
    static func onUnmeteredNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = ResumeOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "SupernoteAutoSyncNetwork"))
        }
    }
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }
}
