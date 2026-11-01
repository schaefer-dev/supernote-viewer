import SwiftUI
import PDFKit

private struct PDFReaderView: UIViewRepresentable {
    let model: ReaderModel
    func makeUIView(context: Context) -> PDFView { model.view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
private struct ThumbnailsView: UIViewRepresentable {
    let model: ReaderModel
    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = model.view; view.layoutMode = .vertical; view.thumbnailSize = CGSize(width: 120, height: 160)
        return view
    }
    func updateUIView(_ view: PDFThumbnailView, context: Context) { view.pdfView = model.view }
}
private struct ShareSheet: UIViewControllerRepresentable {
    // Retains the workspace until the share controller is released.
    let snapshot: DisplayedDocument
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [snapshot.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ReaderScreen: View {
    @Bindable var library: MobileLibrary
    @State private var showingSearch = false
    @State private var showingPages = false
    @State private var showingInfo = false
    @State private var share: ShareSnapshot?
    @State private var inspectorVisible = false
    @State private var readerIdentity: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    struct ShareSnapshot: Identifiable { let id = UUID(); let displayed: DisplayedDocument }
    var body: some View {
        VStack(spacing: 0) {
            if let status = library.opener.status {
                HStack { ProgressView(); Text(status).font(.caption); Spacer(); Button("Cancel") { library.opener.cancel() } }.padding(10)
            }
            if let warning = library.opener.warning {
                VStack(alignment: .leading) {
                    Text(warning).font(.caption)
                    Button("Retry Recognition") { library.opener.retryRecognition() }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.yellow.opacity(0.15))
            }
            if let error = library.opener.error {
                VStack(spacing: 12) {
                    Text(error)
                    Button("Retry") { library.reload() }
                    if library.opener.missingCompanion { Button("Open Annotations Only") { library.reload(annotationsOnly: true) } }
                }.padding()
            }
            if library.opener.displayed != nil {
                PDFReaderView(model: library.reader)
                    .accessibilityLabel("Document pages")
                Text("Page \(library.reader.page + 1) of \(library.reader.document?.pageCount ?? 0)")
                    .font(.caption).foregroundStyle(.secondary).padding(4)
            } else if library.opener.status == nil && library.opener.error == nil {
                ContentUnavailableView("Open a Document", systemImage: "book", description: Text("Choose an example, import a file, or connect Dropbox."))
            } else { Spacer() }
        }
        .navigationTitle(library.opener.reference?.name ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if library.opener.displayed != nil {
                Button("Search", systemImage: "magnifyingglass") { showingSearch = true }.keyboardShortcut("f", modifiers: .command)
                Button("Pages and Titles", systemImage: "sidebar.right") {
                    if sizeClass == .regular { inspectorVisible.toggle() } else { showingPages = true }
                }
                Menu("Document", systemImage: "ellipsis.circle") {
                    Button("Share PDF", systemImage: "square.and.arrow.up") { if let displayed = library.opener.displayed { share = ShareSnapshot(displayed: displayed) } }
                    Button("Reload", systemImage: "arrow.clockwise") { library.reload() }.keyboardShortcut("r", modifiers: .command)
                    Button("Document Information", systemImage: "info.circle") { showingInfo = true }
                }
            }
        }
        .onChange(of: library.opener.displayed?.url, initial: true) { _, _ in
            if readerIdentity != library.opener.reference?.id {
                library.reader.reset(); readerIdentity = library.opener.reference?.id
            }
            if let displayed = library.opener.displayed { library.reader.replace(displayed.document, page: library.opener.page, workspace: displayed.workspace) }
        }
        .inspector(isPresented: $inspectorVisible) { PagesPanel(library: library).inspectorColumnWidth(min: 220, ideal: 280, max: 400) }
        .sheet(isPresented: $showingPages) { NavigationStack { PagesPanel(library: library).navigationTitle("Pages and Titles").toolbar { Button("Done") { showingPages = false } } } }
        .sheet(isPresented: $showingSearch) {
            NavigationStack { SearchPanel(library: library).toolbar { Button("Done") { showingSearch = false } } }.presentationDetents([.medium, .large])
        }
        .sheet(item: $share) { snapshot in
            VStack(spacing: 0) {
                if library.opener.recognizing { Text("This export contains the currently displayed PDF. Some handwriting is still being recognized.").font(.caption).padding() }
                ShareSheet(snapshot: snapshot.displayed)
            }
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                Form {
                    LabeledContent("Name", value: library.opener.reference?.name ?? "")
                    LabeledContent("Source", value: library.opener.reference?.source.rawValue ?? "")
                    LabeledContent("Pages", value: "\(library.reader.document?.pageCount ?? 0)")
                    if let seconds = library.opener.metrics.downloadSeconds { LabeledContent("Download", value: String(format: "%.2f s", seconds)) }
                    if let seconds = library.opener.metrics.previewSeconds { LabeledContent("Preview rendering", value: String(format: "%.2f s", seconds)) }
                    if let seconds = library.opener.metrics.recognitionSeconds { LabeledContent("Handwriting recognition", value: String(format: "%.2f s", seconds)) }
                    if let path = library.opener.reference?.path { LabeledContent("Dropbox path", value: path) }
                    Text("Dropbox documents are fetched again on Open or Reload. Reopening requires a network connection. Imported documents last for this session.").font(.footnote)
                }.navigationTitle("Document Information").toolbar { Button("Done") { showingInfo = false } }
            }.presentationDetents([.medium, .large])
        }
    }
}

private struct PagesPanel: View {
    @Bindable var library: MobileLibrary
    @State private var titles = false
    var body: some View {
        VStack {
            Picker("Navigation", selection: $titles) { Text("Pages").tag(false); Text("Titles").tag(true) }.pickerStyle(.segmented).padding()
            if titles {
                if library.opener.recognizing { Text("Title labels appear after handwriting recognition finishes.").font(.caption).padding() }
                List(library.reader.titles) { title in
                    Button { library.reader.go(to: title.page) } label: {
                        HStack { Text(title.label).padding(.leading, CGFloat(title.depth) * 12); Spacer(); Text("\(title.page + 1)").foregroundStyle(.secondary) }
                    }
                }.overlay { if library.reader.titles.isEmpty { ContentUnavailableView("No titles yet", systemImage: "list.bullet") } }
            } else { ThumbnailsView(model: library.reader) }
        }
    }
}
private struct SearchPanel: View {
    @Bindable var library: MobileLibrary
    var body: some View {
        @Bindable var reader = library.reader
        VStack {
            if library.opener.recognizing { Text("Handwriting recognition is in progress. Search coverage is partial.").font(.caption).padding() }
            List(Array(reader.results.enumerated()), id: \.offset) { _, selection in
                Button { reader.select(selection) } label: {
                    VStack(alignment: .leading) {
                        Text(selection.string ?? "Match")
                        if let page = selection.pages.first, let document = reader.document { Text("Page \(document.index(for: page) + 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if reader.searching { ProgressView("Searching…") }
        }.searchable(text: $reader.query, prompt: "Search this document")
            .onChange(of: reader.query) { _, _ in reader.search() }
            .navigationTitle("Search")
    }
}
