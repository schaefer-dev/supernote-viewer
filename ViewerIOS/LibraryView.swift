import SwiftUI
import UniformTypeIdentifiers

private enum Source: String, CaseIterable, Identifiable {
    case dropbox = "Dropbox", recents = "Recents", examples = "Examples"
    var id: String { rawValue }
    var icon: String { switch self { case .dropbox: "externaldrive.badge.icloud"; case .recents: "clock"; case .examples: "books.vertical" } }
}

struct LibraryView: View {
    @Bindable var library: MobileLibrary
    @State private var source: Source?
    init(library: MobileLibrary) {
        self.library = library
        _source = State(initialValue: Self.initialSource(library))
    }
    /// Start where the user's documents are: Dropbox when connected, then Recents, then Examples.
    private static func initialSource(_ library: MobileLibrary) -> Source {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--start-in-examples") { return .examples }
        #endif
        if library.session.state == .connected { return .dropbox }
        return library.recents.records.isEmpty ? .examples : .recents
    }
    @State private var compactColumn: NavigationSplitViewColumn = .content
    @State private var importing = false
    @State private var importingOriginal = false
    @State private var showingSettings = false
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(Source.allCases, selection: $source) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                .navigationTitle("Supernote")
                .toolbar {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                }
        } content: {
            NavigationStack {
                Group {
                    switch source ?? .examples {
                    case .examples: ExamplesList(library: library, opened: { compactColumn = .detail })
                    case .recents: RecentsList(library: library, opened: { compactColumn = .detail })
                    case .dropbox: DropboxLanding(library: library, opened: { compactColumn = .detail })
                    }
                }
                // Large titles do not render in this split-view column on iOS 26; inline titles do.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Import from Files…", systemImage: "square.and.arrow.down") { importing = true }
                            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        }
                    }
                }
            }
        } detail: {
            ReaderScreen(library: library)
        }
        .onChange(of: library.opener.reference?.id) { _, identity in
            if identity != nil { compactColumn = .detail }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(library: library, chooseFolder: { source = .dropbox }) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(exportedAs: "dev.schaefer.supernote.note"), UTType(exportedAs: "dev.schaefer.supernote.mark")], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): library.importFiles(urls); compactColumn = .detail
            case .failure(let error): library.importError = error.localizedDescription }
        }
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
    var availableOffline = false
    var body: some View {
        HStack(spacing: 14) {
            DocumentThumbnail(image: thumbnail, kind: kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
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

private struct ExamplesList: View {
    @Bindable var library: MobileLibrary
    let opened: () -> Void
    var body: some View {
        List {
            Section {
                ForEach(MobileLibrary.exampleURLs, id: \.self) { url in
                    Button { library.openExample(url); opened() } label: {
                        DocumentRow(name: displayName(url.lastPathComponent), kind: DocumentKind(fileName: url.lastPathComponent), detail: "Example")
                    }
                    .accessibilityIdentifier(url.lastPathComponent)
                }
            } footer: {
                Text("Sample notebooks and annotated PDFs that show how Supernote Viewer renders handwriting.")
            }
        }
        .navigationTitle("Examples")
    }
}

private struct RecentsList: View {
    @Bindable var library: MobileLibrary
    let opened: () -> Void
    var body: some View {
        List(library.recents.records) { recent in
            Button { library.openRecent(recent); opened() } label: {
                DocumentRow(name: displayName(recent.reference.name), kind: DocumentKind(fileName: recent.reference.name),
                            detail: "Page \(recent.page + 1) · \(recent.opened.formatted(.relative(presentation: .named)))",
                            thumbnail: recent.reference.source == .dropbox
                                ? library.thumbnails.thumbnail(account: recent.reference.accountID, fileID: recent.reference.fileID) : nil)
            }
            .swipeActions { Button("Remove", systemImage: "trash", role: .destructive) { library.recents.remove(recent) } }
        }
        .navigationTitle("Recents")
        .overlay {
            if library.recents.records.isEmpty {
                ContentUnavailableView("No Recent Documents", systemImage: "clock",
                                       description: Text("Documents you open appear here, ready to reopen at the page where you stopped."))
            }
        }
    }
}

private struct DropboxLanding: View {
    @Bindable var library: MobileLibrary
    #if DEBUG
    static let unconfiguredText = "Add your Dropbox app key using scripts/prepare-ios.py. Examples and Files import are ready to use."
    #else
    static let unconfiguredText = "Dropbox is not available in this build. Examples and Files import are ready to use."
    #endif
    let opened: () -> Void
    var body: some View {
        Group {
            if library.session.state == .connected, let account = library.session.accountID {
                FolderView(library: library, folder: library.choosingRoot ? nil : library.recents.root(account: account), opened: opened)
                    .id(library.choosingRoot)
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
        .navigationTitle("Dropbox")
        .task(id: library.session.state) { await library.session.loadAccount() }
    }
}

private struct FolderView: View {
    @Bindable var library: MobileLibrary
    let folder: RemoteEntry?
    let opened: () -> Void
    @State private var model = FolderBrowserModel()
    @State private var filter = ""
    private var isLibraryRoot: Bool {
        guard let account = library.session.accountID else { return false }
        return library.recents.root(account: account)?.id == folder?.id && !library.choosingRoot
    }
    private var visibleItems: [LibraryItem] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.items : model.items.filter { $0.name.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            if library.choosingRoot {
                Section {
                    Text("Browse to the folder that holds your Supernote files, then tap Use This Folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
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
                        NavigationLink(value: item.entry) { FolderRow(name: item.name) }
                    } else {
                        Button { library.openRemote(item.entry); opened() } label: {
                            DocumentRow(name: item.name, kind: item.kind, detail: item.detail,
                                        thumbnail: library.thumbnails.thumbnail(account: library.session.accountID, fileID: item.entry.id),
                                        availableOffline: model.available.contains(item.id))
                        }
                        .contextMenu {
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
        .navigationTitle(folder?.name ?? "Dropbox")
        .navigationDestination(for: RemoteEntry.self) { child in FolderView(library: library, folder: child, opened: opened) }
        .toolbar {
            if library.choosingRoot {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder") {
                        if let account = library.session.accountID { library.recents.setRoot(folder, account: account) }
                        library.choosingRoot = false
                    }
                }
            } else if isLibraryRoot {
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
                        Button("Download \(plan.items.count)") { sync.start(service: library.service) }.buttonStyle(.borderedProminent)
                        Button("Not Now") { sync.dismiss() }.buttonStyle(.bordered)
                    }
                }
            case .running:
                HStack {
                    Label("Syncing library", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Spacer()
                    Button("Cancel") { sync.cancel() }.buttonStyle(.borderless)
                }
                ProgressView(value: sync.fraction)
                Text("\(min(sync.completed + 1, sync.plan?.items.count ?? 0)) of \(sync.plan?.items.count ?? 0) · \(sync.current ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("You can keep reading. Sync continues in the background where iOS allows.")
                    .font(.caption2).foregroundStyle(.tertiary)
            case .finished, .failed:
                Label(sync.message ?? "", systemImage: sync.phase == .finished && sync.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(sync.phase == .finished && sync.failures.isEmpty ? .green : .orange)
                    .font(.callout)
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
        var parts = ["\(plan.items.count) documents (\(ByteCountFormatter.string(fromByteCount: Int64(plan.bytes), countStyle: .file))) will be downloaded and their handwriting recognized."]
        if plan.upToDate > 0 { parts.append("\(plan.upToDate) are already available offline.") }
        if plan.missingOriginals > 0 { parts.append("\(plan.missingOriginals) annotated PDFs are skipped because their original PDF is missing.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var library: MobileLibrary
    let chooseFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var usage: (documents: Int, bytes: UInt64)?
    @State private var confirmingRemoval = false
    @State private var confirmingDisconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Dropbox") {
                    if library.session.state == .connected {
                        LabeledContent("Account", value: library.session.accountName ?? "Connected")
                        LabeledContent("Library folder", value: libraryFolderName)
                        Button("Choose Library Folder") { library.choosingRoot = true; chooseFolder(); dismiss() }
                        Button("Disconnect Dropbox", role: .destructive) { confirmingDisconnect = true }
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                        if library.session.state != .unconfigured {
                            Button("Connect Dropbox") { library.session.connect() }
                        }
                    }
                }
                Section {
                    LabeledContent("Saved documents") {
                        if let usage {
                            Text("\(usage.documents) · \(ByteCountFormatter.string(fromByteCount: Int64(usage.bytes), countStyle: .file))")
                        } else { ProgressView() }
                    }
                    if library.session.state == .connected {
                        Button("Sync Library for Offline Use") { library.startSyncCheck(); chooseFolder(); dismiss() }
                            .disabled(library.sync.isActive)
                    }
                    Button("Remove Downloaded Documents", role: .destructive) { confirmingRemoval = true }
                        .disabled(usage?.documents == 0)
                } header: { Text("Offline") } footer: {
                    Text("Opened and synced documents are kept on this iPhone in their newest version, so they open instantly and without a connection. Removing them never changes your Dropbox.")
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
            .confirmationDialog("Remove all downloaded documents from this iPhone?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("Remove Downloads", role: .destructive) { library.removeDownloads() }
            } message: { Text("Your Dropbox files are not affected. Documents download again when you open or sync them.") }
            .confirmationDialog("Disconnect Dropbox?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { library.disconnect(); dismiss() }
            } message: { Text("Recents and downloaded documents for this account are removed from this iPhone.") }
        }
    }
    private var libraryFolderName: String {
        guard let account = library.session.accountID, let root = library.recents.root(account: account) else { return "All of Dropbox" }
        return root.name
    }
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
