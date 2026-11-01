import SwiftUI
import UniformTypeIdentifiers

private enum Source: String, CaseIterable, Identifiable {
    case dropbox = "Dropbox", recents = "Recents", examples = "Examples"
    var id: String { rawValue }
    var icon: String { switch self { case .dropbox: "externaldrive.badge.icloud"; case .recents: "clock"; case .examples: "books.vertical" } }
}

struct LibraryView: View {
    @Bindable var library: MobileLibrary
    @State private var source: Source? = .examples
    @State private var compactColumn: NavigationSplitViewColumn = .content
    @State private var importing = false
    @State private var importingOriginal = false
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(Source.allCases, selection: $source) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                .navigationTitle("Supernote")
                .toolbar { Button("Import", systemImage: "square.and.arrow.down") { importing = true } }
        } content: {
            NavigationStack {
                Group {
                    switch source ?? .examples {
                    case .examples:
                        List(MobileLibrary.exampleURLs, id: \.self) { url in
                            Button { library.openExample(url); compactColumn = .detail } label: { Label(url.lastPathComponent, systemImage: "book.closed") }
                        }.navigationTitle("Examples")
                    case .recents:
                        List(library.recents.records) { recent in
                            Button { library.openRecent(recent); compactColumn = .detail } label: {
                                VStack(alignment: .leading) { Text(recent.reference.name); Text("Page \(recent.page + 1)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.navigationTitle("Recents").overlay { if library.recents.records.isEmpty { ContentUnavailableView("No recent documents", systemImage: "clock") } }
                    case .dropbox: DropboxLanding(library: library, opened: { compactColumn = .detail })
                    }
                }
                .toolbar { Button("Import", systemImage: "square.and.arrow.down") { importing = true } }
            }
        } detail: {
            ReaderScreen(library: library)
        }
        .onChange(of: library.opener.reference?.id) { _, identity in
            if identity != nil { compactColumn = .detail }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, UTType(exportedAs: "dev.schaefer.supernote.note"), UTType(exportedAs: "dev.schaefer.supernote.mark")], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): library.importFiles(urls); compactColumn = .detail
            case .failure(let error): library.importError = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { library.pendingImport != nil && !importingOriginal }, set: { if !$0 && !importingOriginal { library.pendingImport = nil } })) {
            NavigationStack {
                VStack(spacing: 24) {
                    Text("Choose the original PDF for these annotations. Select both files together during import to open them in one step.")
                    Button("Choose Original PDF") { importingOriginal = true }
                    Button("Open Annotations Only") {
                        if let url = library.pendingImport { library.openImport(url, companion: nil, annotationsOnly: true) }
                        library.pendingImport = nil; compactColumn = .detail
                    }
                }.padding().navigationTitle("Original PDF Needed")
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

private struct DropboxLanding: View {
    @Bindable var library: MobileLibrary
    let opened: () -> Void
    @State private var choosingRoot = false
    var body: some View {
        Group {
            if library.session.state == .connected, let account = library.session.accountID {
                FolderView(library: library, folder: choosingRoot ? nil : library.recents.root(account: account), opened: opened, rootChosen: { choosingRoot = false })
            } else {
                ContentUnavailableView {
                    Label("Connect to Dropbox", systemImage: "externaldrive.badge.icloud")
                } description: {
                    Text(library.session.state == .unconfigured ? "Add your Dropbox app key using scripts/prepare-ios.py. Examples and Files import are ready to use." : library.session.error ?? "Browse your Supernote folder and open documents online.")
                } actions: {
                    if library.session.state != .unconfigured { Button(library.session.state == .connecting ? "Try Connecting Again" : "Connect Dropbox") { library.session.connect() } }
                }
            }
        }.navigationTitle("Dropbox")
            .toolbar {
                if library.session.state == .connected {
                    Menu("Account", systemImage: "person.crop.circle") {
                        Text(library.session.accountName ?? "Dropbox")
                        Button("Choose Library Folder") { choosingRoot = true }
                        Button("Disconnect", role: .destructive) { library.opener.cancel(); library.session.disconnect() }
                    }
                }
            }
            .task(id: library.session.state) { await library.session.loadAccount() }
    }
}

private struct FolderView: View {
    @Bindable var library: MobileLibrary
    let folder: RemoteEntry?
    let opened: () -> Void
    let rootChosen: () -> Void
    @State private var model = FolderBrowserModel()
    var body: some View {
        List {
            if let error = model.error {
                Section { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await refresh() } } }
            }
            ForEach(model.items) { item in
                if item.entry.isFolder {
                    NavigationLink(value: item.entry) { Label(item.name, systemImage: item.icon) }
                } else {
                    Button { library.openRemote(item.entry); opened() } label: { Label(item.name, systemImage: item.icon) }
                        .contextMenu { if let original = item.original { Button("Open Original") { library.openRemote(original); opened() } } }
                }
            }
            if model.loading { ProgressView("Loading folder…") }
            if model.items.isEmpty && !model.loading && model.error == nil { Text("No supported documents in this folder.").foregroundStyle(.secondary) }
        }
        .navigationTitle(folder?.name ?? "Dropbox Root")
        .navigationDestination(for: RemoteEntry.self) { child in FolderView(library: library, folder: child, opened: opened, rootChosen: rootChosen) }
        .toolbar {
            Button("Use This Folder") {
                if let account = library.session.accountID { library.recents.setRoot(folder, account: account); rootChosen() }
            }
        }
        .refreshable { await refresh() }
        .task(id: folder?.id) { await refresh() }
    }
    private func refresh() async { await model.refresh(service: library.service, folder: folder) }
}
