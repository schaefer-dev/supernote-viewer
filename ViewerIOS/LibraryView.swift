import SwiftUI
import UniformTypeIdentifiers

/// Screens pushed onto the library column: Home → Browse Dropbox → folders.
enum LibraryRoute: Hashable {
    case favorites
    case dropbox
    case folder(RemoteEntry)
}

struct LibraryView: View {
    @Bindable var library: MobileLibrary
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var importingOriginal = false
    @State private var showingSettings = false
    @State private var columns: NavigationSplitViewVisibility = .all
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        // Two columns: the library (a navigation stack starting at Home) and the reader. On iPhone the
        // reader is pushed over the library, so Back returns to wherever the document was opened from.
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            NavigationStack(path: $library.path) {
                HomeView(library: library, showSettings: { showingSettings = true },
                         opened: { compactColumn = .detail })
                    .navigationDestination(for: LibraryRoute.self) { route in
                        switch route {
                        case .favorites: FavoritesView(library: library, opened: { compactColumn = .detail })
                        case .dropbox: DropboxLanding(library: library, opened: { compactColumn = .detail })
                        case .folder(let folder): FolderView(library: library, folder: folder, opened: { compactColumn = .detail })
                        }
                    }
            }
            // The sidebar column owns the system toggle, even when it appears over the reader.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ReaderScreen(library: library,
                         showLibrary: sizeClass == .regular && columns == .detailOnly ? { withAnimation { columns = .all } } : nil)
        }
        // The library column slides over the page instead of squeezing it.
        .navigationSplitViewStyle(.prominentDetail)
        .onChange(of: library.opener.reference?.id) { _, identity in
            guard identity != nil else { return }
            compactColumn = .detail
            // Give the page the whole screen; the reader's Library button brings the library back.
            // A document opened while the app launches (from Files, say) arrives while the split view
            // is still settling its first layout and resets the columns, so collapse once more after it.
            guard sizeClass != .compact else { return }
            withAnimation { columns = .detailOnly }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if library.opener.reference?.id == identity, columns != .detailOnly { withAnimation { columns = .detailOnly } }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(library: library) }
        // Choosing the Supernote folder is the required step after connecting Dropbox.
        .sheet(isPresented: Binding(get: { library.needsLibraryFolder && !showingSettings }, set: { _ in })) {
            NavigationStack { LibraryFolderPicker(library: library, folder: nil, chosen: {}) }
                .interactiveDismissDisabled()
        }
        // Annotations handed over by another app may still need their original PDF. This must stay the
        // only .fileImporter on this view: SwiftUI honours just the last one attached.
        .sheet(isPresented: Binding(get: { library.pendingImport != nil && !importingOriginal }, set: { if !$0 && !importingOriginal { library.pendingImport = nil } })) {
            NavigationStack {
                ContentUnavailableView {
                    Label("Original PDF Needed", systemImage: "doc.richtext")
                } description: {
                    Text("These annotations belong to a PDF. Choose the original to see them in place, or select both files together next time.")
                } actions: {
                    Button("Choose Original PDF") { importingOriginal = true }.buttonStyle(.borderedProminent)
                    Button("Open Annotations Only") {
                        if let url = library.pendingImport { library.openImport(url, companion: nil, annotationsOnly: true) }
                        library.pendingImport = nil; compactColumn = .detail
                    }
                }
                .toolbar { Button("Cancel") { library.pendingImport = nil } }
            }.presentationDetents([.medium])
        }
        .fileImporter(isPresented: $importingOriginal, allowedContentTypes: [.pdf]) { result in
            switch result { case .success(let url): library.importFiles([url]); compactColumn = .detail
            case .failure(let error): library.importError = error.localizedDescription }
        }
        .alert("Unable to Open", isPresented: Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })) {
            Button("OK") { library.importError = nil }
        } message: { Text(library.importError ?? "") }
    }
}

// MARK: - Home

/// The start screen: sync status, the way into Dropbox, favorites and recently opened documents.
private struct HomeView: View {
    @Bindable var library: MobileLibrary
    let showSettings: () -> Void
    let opened: () -> Void
    private static let pageSize = 10
    @State private var recentLimit = Self.pageSize
    private var connected: Bool { library.session.state == .connected && library.session.accountID != nil }
    private var libraryFolderName: String {
        guard connected else { return library.session.state == .unconfigured ? "Unavailable" : "Not Connected" }
        return library.libraryRoot?.name ?? "Choose Folder"
    }
    var body: some View {
        List {
            if library.sync.phase != .idle {
                Section { SyncCard(library: library) }
            }
            Section("Library") {
                NavigationLink(value: LibraryRoute.dropbox) {
                    LabeledContent {
                        Text(libraryFolderName)
                    } label: {
                        Label("Browse Dropbox", systemImage: "externaldrive.badge.icloud")
                    }
                }
                .accessibilityIdentifier("Browse Dropbox")
            }
            Section("Favorites") {
                if library.accountFavorites.isEmpty {
                    Text("Star documents, or pages in the reader, to keep them handy here.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(library.accountFavorites.prefix(5)) { favorite in
                        FavoriteRow(library: library, favorite: favorite, opened: opened)
                    }
                    if library.accountFavorites.count > 5 {
                        NavigationLink("Show All", value: LibraryRoute.favorites)
                    } else {
                        NavigationLink("Edit Favorites", value: LibraryRoute.favorites)
                    }
                }
            }
            if library.recents.records.isEmpty {
                if !connected && library.session.state != .unconfigured {
                    Section {
                        ContentUnavailableView {
                            Label("Connect Dropbox", systemImage: "externaldrive.badge.icloud")
                        } description: {
                            Text("See the notebooks and annotated PDFs your Supernote syncs to Dropbox. Access is read-only.")
                        } actions: {
                            Button("Connect Dropbox") { library.session.connect() }.buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Section("Recently Opened") {
                        Text("Documents you open appear here, ready to reopen at the page where you stopped.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Recently Opened") {
                    ForEach(library.recents.records.prefix(recentLimit)) { recent in
                        Button { library.openRecent(recent); opened() } label: {
                            RecentRow(library: library, recent: recent)
                        }
                        .contextMenu { FavoriteAction(library: library, reference: recent.reference) }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) { FavoriteAction(library: library, reference: recent.reference) }
                        .swipeActions { Button("Remove", systemImage: "trash", role: .destructive) { library.recents.remove(recent) } }
                    }
                    if library.recents.records.count > recentLimit {
                        Button { withAnimation { recentLimit += Self.pageSize } } label: {
                            Text("Load More").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .navigationTitle("Supernote Viewer")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gearshape", action: showSettings)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync All", systemImage: "arrow.triangle.2.circlepath") { library.startSyncCheck() }
                    .disabled(!connected || library.libraryRoot == nil || library.sync.isActive)
            }
        }
    }
}

// MARK: - Rows

/// A page-shaped thumbnail, or the document kind's symbol when no rendering is saved.
struct DocumentThumbnail: View {
    let image: UIImage?
    let kind: DocumentKind
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: kind.symbol).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 42, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct DocumentRow: View {
    let name: String
    let kind: DocumentKind
    let detail: String?
    var thumbnail: UIImage? = nil
    var isFavorite = false
    var availableOffline = false
    var body: some View {
        HStack(spacing: 14) {
            DocumentThumbnail(image: thumbnail, kind: kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill").font(.footnote).foregroundStyle(.yellow).accessibilityLabel("Favorite")
            }
            if availableOffline {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
                    .accessibilityLabel("Available offline")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct FolderRow: View {
    let name: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint).frame(width: 42)
            Text(name).foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lists

/// A recent document with its thumbnail, last page and when it was opened.
private struct RecentRow: View {
    @Bindable var library: MobileLibrary
    let recent: RecentDocument
    var body: some View {
        DocumentRow(name: displayName(recent.reference.name), kind: DocumentKind(fileName: recent.reference.name),
                    detail: "Page \(recent.page + 1) · \(recent.opened.formatted(.relative(presentation: .named)))",
                    thumbnail: recent.reference.source == .dropbox
                        ? library.thumbnails.thumbnail(account: recent.reference.accountID, fileID: recent.reference.fileID) : nil,
                    isFavorite: library.favorites.isFavorite(recent.reference))
    }
}

private struct DropboxLanding: View {
    @Bindable var library: MobileLibrary
    #if DEBUG
    static let unconfiguredText = "Add your Dropbox app key using scripts/prepare-ios.py."
    #else
    static let unconfiguredText = "Dropbox is not available in this build."
    #endif
    let opened: () -> Void
    var body: some View {
        Group {
            if library.session.state == .connected, library.session.accountID != nil {
                FolderView(library: library, folder: library.libraryRoot, opened: opened)
            } else {
                ContentUnavailableView {
                    Label("Connect to Dropbox", systemImage: "externaldrive.badge.icloud")
                } description: {
                    Text(library.session.state == .unconfigured ? Self.unconfiguredText : library.session.error ?? "Open notebooks and annotated PDFs from your Supernote sync folder. Supernote Viewer asks Dropbox for read-only access: it can list and download your files, but never changes, uploads or deletes anything.")
                } actions: {
                    if library.session.state != .unconfigured {
                        Button(library.session.state == .connecting ? "Try Connecting Again" : "Connect Dropbox") { library.session.connect() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("Browse Dropbox")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.session.state) { await library.session.loadAccount() }
    }
}

private struct FolderView: View {
    @Bindable var library: MobileLibrary
    let folder: RemoteEntry?
    let opened: () -> Void
    @State private var model = FolderBrowserModel()
    @State private var filter = ""
    private var isLibraryRoot: Bool { library.libraryRoot != nil && library.libraryRoot?.id == folder?.id }
    private var visibleItems: [LibraryItem] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.items : model.items.filter { $0.name.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            if isLibraryRoot && library.sync.phase != .idle {
                Section { SyncCard(library: library) }
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Retry") { Task { await refresh() } }
                }
            }
            Section {
                ForEach(visibleItems) { item in
                    if item.entry.isFolder {
                        NavigationLink(value: LibraryRoute.folder(item.entry)) { FolderRow(name: item.name) }
                    } else {
                        Button { library.openRemote(item.entry); opened() } label: {
                            DocumentRow(name: item.name, kind: item.kind, detail: item.detail,
                                        thumbnail: library.thumbnails.thumbnail(account: library.session.accountID, fileID: item.entry.id),
                                        isFavorite: library.session.accountID.map { library.favorites.isFavorite(.remote(item.entry, account: $0)) } ?? false,
                                        availableOffline: model.available.contains(item.id))
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if let account = library.session.accountID { FavoriteAction(library: library, reference: .remote(item.entry, account: account)) }
                        }
                        .contextMenu {
                            if let account = library.session.accountID { FavoriteAction(library: library, reference: .remote(item.entry, account: account)) }
                            Button("Open", systemImage: "doc.text") { library.openRemote(item.entry); opened() }
                            if let original = item.original {
                                Button("Open Original PDF", systemImage: "doc") { library.openRemote(original); opened() }
                            }
                        }
                    }
                }
            }
            if model.loading && model.items.isEmpty {
                HStack { Spacer(); ProgressView("Loading folder…"); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .overlay {
            if model.items.isEmpty && !model.loading && model.error == nil {
                ContentUnavailableView("No Supernote Documents", systemImage: "folder",
                                       description: Text("This folder has no notebooks, annotated PDFs or PDFs."))
            } else if !filter.isEmpty && visibleItems.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .searchable(text: $filter, prompt: "Filter by name")
        .navigationTitle(folder?.name ?? "Browse Dropbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isLibraryRoot {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sync for Offline Use", systemImage: "arrow.down.circle") { library.startSyncCheck() }
                        .disabled(library.sync.isActive)
                }
            }
        }
        .refreshable { await refresh() }
        .task(id: folder?.id) { await refresh() }
        .task(id: "\(library.savedGeneration):\(model.items.count)") {
            await model.refreshAvailability(account: library.session.accountID, cache: .shared)
        }
    }
    private func refresh() async { await model.refresh(service: library.service, folder: folder) }
}

// MARK: - Library folder

/// Browses Dropbox folders to choose the one the Supernote syncs to. Only folders are listed;
/// a folder's document count confirms the choice before Use This Folder.
private struct LibraryFolderPicker: View {
    @Bindable var library: MobileLibrary
    let folder: RemoteEntry?
    let chosen: () -> Void
    @State private var model = FolderBrowserModel()
    private var folders: [LibraryItem] { model.items.filter(\.entry.isFolder) }
    private var documentCount: Int { model.items.count - folders.count }
    var body: some View {
        List {
            if folder == nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where does your Supernote sync?").font(.headline)
                        Text("Choose the Dropbox folder your Supernote syncs to, usually “Supernote”. Browse Dropbox and Sync All start there. You can change it later in Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                let suggested = LibraryItem.supernoteFolders(in: model.items)
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested) { item in
                            HStack {
                                FolderRow(name: item.name)
                                Spacer()
                                Button("Use") { choose(item.entry) }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Retry") { Task { await refresh() } }
                }
            }
            Section {
                ForEach(folders) { item in
                    NavigationLink {
                        LibraryFolderPicker(library: library, folder: item.entry, chosen: chosen)
                    } label: { FolderRow(name: item.name) }
                }
                if model.loading && model.items.isEmpty {
                    HStack { Spacer(); ProgressView("Loading folders…"); Spacer() }.listRowBackground(Color.clear)
                } else if folders.isEmpty && model.error == nil {
                    Text("No folders inside").foregroundStyle(.secondary)
                }
            } header: {
                Text(folder == nil ? "All Folders" : "Folders")
            } footer: {
                if folder != nil && !model.loading {
                    Text(documentCount == 1 ? "1 Supernote document in this folder." : "\(documentCount) Supernote documents in this folder.")
                }
            }
        }
        .navigationTitle(folder?.name ?? "Choose Supernote Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let folder {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder") { choose(folder) }
                }
            }
        }
        .refreshable { await refresh() }
        .task(id: folder?.id) { await refresh() }
    }
    private func refresh() async { await model.refresh(service: library.service, folder: folder) }
    private func choose(_ entry: RemoteEntry) {
        library.chooseLibraryFolder(entry)
        chosen()
    }
}

// MARK: - Sync

struct SyncCard: View {
    @Bindable var library: MobileLibrary
    private var sync: LibrarySync { library.sync }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch sync.phase {
            case .idle: EmptyView()
            case .checking:
                HStack(spacing: 10) { ProgressView(); Text("Checking your library…") }
            case .ready:
                if let plan = sync.plan {
                    Label("Download for offline use", systemImage: "arrow.down.circle").font(.headline)
                    Text(readyText(plan)).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Sync \(plan.items.count)") { sync.start(service: library.service) }.buttonStyle(.borderedProminent)
                        Button("Not Now") { sync.dismiss() }.buttonStyle(.bordered)
                    }
                }
            case .running:
                HStack {
                    Label(sync.pass == .readable ? "Making documents readable offline" : "Adding searchable handwriting",
                          systemImage: sync.pass == .readable ? "arrow.down.circle" : "text.magnifyingglass").font(.headline)
                    Spacer()
                    Button("Cancel") { sync.cancel() }.buttonStyle(.borderless)
                }
                ProgressView(value: sync.fraction)
                Text("Step \(sync.pass == .readable ? 1 : 2) of 2 · \(min(sync.completed + 1, sync.passTotal)) of \(sync.passTotal) · \(sync.current ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(sync.pass == .readable
                     ? "Documents become readable offline first, newest first. Handwriting search is added in step 2."
                     : "Everything synced is already readable offline. You can keep reading while search is added.")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .finished, .failed:
                Label(sync.message ?? "", systemImage: sync.phase == .finished && sync.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(sync.phase == .finished && sync.failures.isEmpty ? .green : .orange)
                    .font(.callout)
                if sync.phase == .finished, sync.timings != SyncTimings() {
                    Text(timingText(sync.timings)).font(.caption2).foregroundStyle(.tertiary)
                }
                if !sync.unsearchable.isEmpty {
                    Text("Readable but not searchable: " + sync.unsearchable.prefix(5).joined(separator: ", ") + (sync.unsearchable.count > 5 ? "…" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !sync.failures.isEmpty {
                    Text("Not synced: " + sync.failures.prefix(5).joined(separator: ", ") + (sync.failures.count > 5 ? "…" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if sync.phase == .failed || !sync.failures.isEmpty {
                        Button("Try Again") { library.startSyncCheck() }.buttonStyle(.bordered)
                    }
                    Button("Done") { sync.dismiss() }.buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
    private func readyText(_ plan: SyncPlan) -> String {
        var parts: [String] = []
        let readable = plan.readablePass.count, searchable = plan.searchablePass.count
        if readable > 0 {
            parts.append("\(readable) documents (\(ByteCountFormatter.string(fromByteCount: Int64(plan.downloadBytes), countStyle: .file))) will be downloaded and made readable offline, newest first.")
        }
        if searchable > 0 { parts.append("Handwriting search is then added to \(searchable) documents.") }
        if plan.upToDate > 0 { parts.append("\(plan.upToDate) are already up to date.") }
        if plan.missingOriginals > 0 { parts.append("\(plan.missingOriginals) annotated PDFs are skipped because their original PDF is missing.") }
        return parts.joined(separator: " ")
    }
    private func timingText(_ timings: SyncTimings) -> String {
        let format = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        func text(_ seconds: TimeInterval) -> String { Duration.seconds(seconds.rounded()).formatted(format) }
        return "Waiting for downloads \(text(timings.waitingForDownloads)) · Rendering \(text(timings.rendering)) · Handwriting recognition \(text(timings.recognizing))"
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AutoSyncSettings.enabledKey) private var autoSync = false
    @AppStorage(AutoSyncSettings.wifiOnlyKey) private var autoSyncWiFiOnly = true
    @AppStorage(FavoriteThumbnailSettings.bookmarkedPageKey) private var showsBookmarkedPage = true
    @State private var usage: (documents: Int, bytes: UInt64)?
    @State private var confirmingRemoval = false
    @State private var confirmingDisconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Dropbox") {
                    if library.session.state == .connected {
                        LabeledContent("Account", value: library.session.accountName ?? "Connected")
                        NavigationLink {
                            LibraryFolderPicker(library: library, folder: nil, chosen: { dismiss() })
                        } label: {
                            LabeledContent("Supernote Folder") {
                                if let root = library.libraryRoot { Text(root.name) } else { Text("Required").foregroundStyle(.red) }
                            }
                        }
                        Button("Disconnect Dropbox", role: .destructive) { confirmingDisconnect = true }
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                        if library.session.state != .unconfigured {
                            Button("Connect Dropbox") { library.session.connect() }
                        }
                    }
                }
                Section {
                    Toggle("Sync All When App Opens", isOn: $autoSync)
                    Toggle("Only on Wi-Fi", isOn: $autoSyncWiFiOnly).disabled(!autoSync)
                    if library.session.state == .connected && library.libraryRoot != nil {
                        Button("Sync All Now") { library.startSyncCheck(); library.path = []; dismiss() }
                            .disabled(library.sync.isActive)
                    }
                } header: { Text("Sync") } footer: {
                    Text("Downloads new and changed documents from your library folder each time Supernote Viewer opens, so they are ready to read offline.")
                }
                Section {
                    Toggle("Show Bookmarked Page", isOn: $showsBookmarkedPage)
                } header: { Text("Favorites") } footer: {
                    Text("Favorited pages preview the page you bookmarked instead of the document’s first page.")
                }
                Section {
                    LabeledContent("Saved documents") {
                        if let usage {
                            Text("\(usage.documents) · \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file))")
                        } else { ProgressView() }
                    }
                    Button("Remove Downloaded Documents", role: .destructive) { confirmingRemoval = true }
                        .disabled(usage?.documents == 0)
                } header: { Text("Offline") } footer: {
                    Text("Opened and synced documents are kept on this \(deviceName) in their newest version, so they open instantly and without a connection. Removing them never changes your Dropbox.")
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Text("Supernote Viewer reads your notebooks with read-only Dropbox access. It never changes, uploads or deletes your files.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: library.savedGeneration) {
                usage = await Task.detached(priority: .utility) { RenderedPDFCache.shared.usage() }.value
            }
            .confirmationDialog("Remove all downloaded documents from this \(deviceName)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove Downloads", role: .destructive) { library.removeDownloads() }
            } message: { Text("Your Dropbox files are not affected. Documents download again when you open or sync them.") }
            .confirmationDialog("Disconnect Dropbox?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { library.disconnect(); dismiss() }
            } message: { Text("Favorites, recents and downloaded documents for this account are removed from this \(deviceName).") }
        }
    }
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Stars or unstars a whole document from a list.
struct FavoriteAction: View {
    @Bindable var library: MobileLibrary
    let reference: DocumentReference
    var body: some View {
        if reference.source == .dropbox {
            let starred = library.favorites.isDocumentFavorite(reference)
            Button(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.fill" : "star") {
                library.favorites.toggleDocument(reference)
            }
            .tint(.orange)
        }
    }
}

private struct FavoriteRow: View {
    @Bindable var library: MobileLibrary
    let favorite: FavoriteDocument
    let opened: () -> Void
    @AppStorage(FavoriteThumbnailSettings.bookmarkedPageKey) private var showsBookmarkedPage = true
    private var document: String { displayName(favorite.reference.name) }
    private var kind: DocumentKind { DocumentKind(fileName: favorite.reference.name) }
    var body: some View {
        Button { library.open(favorite); opened() } label: {
            if let page = favorite.bookmarkedPage {
                // A bookmarked page leads with its title, so "that recipe" is findable by name.
                DocumentRow(name: favorite.title ?? "Page \(page + 1)", kind: kind,
                            detail: "\(document) · Page \(page + 1)",
                            thumbnail: library.thumbnails.thumbnail(account: favorite.reference.accountID, fileID: favorite.reference.fileID,
                                                                    page: showsBookmarkedPage ? page : 0))
            } else {
                DocumentRow(name: document, kind: kind, detail: kind.label,
                            thumbnail: library.thumbnails.thumbnail(account: favorite.reference.accountID, fileID: favorite.reference.fileID))
            }
        }
        .contextMenu { remove }
        .swipeActions { remove }
    }
    private var remove: some View {
        Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) { library.favorites.remove(favorite) }
    }
}

private struct FavoritesView: View {
    @Bindable var library: MobileLibrary
    let opened: () -> Void
    var body: some View {
        List {
            ForEach(library.accountFavorites) { favorite in
                FavoriteRow(library: library, favorite: favorite, opened: opened)
            }
            .onDelete { offsets in
                let records = library.accountFavorites
                for index in offsets { library.favorites.remove(records[index]) }
            }
            .onMove { offsets, destination in
                if let account = library.session.accountID { library.favorites.move(from: offsets, to: destination, account: account) }
            }
        }
        .overlay { if library.accountFavorites.isEmpty { ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Star documents, or pages in the reader, to keep them handy here.")) } }
        .navigationTitle("Favorites")
        .toolbar { EditButton() }
    }
}
