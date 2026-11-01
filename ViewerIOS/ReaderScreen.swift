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
    /// Set while the library columns are hidden on iPad; shows the library again.
    var showLibrary: (() -> Void)? = nil
    @State private var showingSearch = false
    @State private var showingPages = false
    @State private var showingInfo = false
    @State private var share: ShareSnapshot?
    @State private var inspectorVisible = false
    @State private var readerIdentity: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    struct ShareSnapshot: Identifiable { let id = UUID(); let displayed: DisplayedDocument }
    @State private var pageIndicatorVisible = false
    var body: some View {
        ZStack {
            if library.opener.displayed != nil {
                PDFReaderView(model: library.reader)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityLabel("Document pages")
                    .overlay(alignment: .top) { banners }
                    .overlay(alignment: .bottom) { pageIndicator }
            } else if let error = library.opener.error {
                ContentUnavailableView {
                    Label(library.opener.errorIsOffline ? "You're Offline" : "Couldn't Open Document",
                          systemImage: library.opener.errorIsOffline ? "wifi.slash" : "exclamationmark.triangle")
                } description: {
                    Text(library.opener.errorIsOffline
                         ? "This document hasn't been saved on this \(deviceName) yet. Connect to the internet and try again, or sync your library for offline use."
                         : error)
                } actions: {
                    Button("Try Again") { library.reload() }.buttonStyle(.borderedProminent)
                    if library.opener.missingCompanion { Button("Open Annotations Only") { library.reload(annotationsOnly: true) } }
                }
            } else if let status = library.opener.status {
                VStack(spacing: 14) {
                    if let fraction = library.opener.fraction {
                        ProgressView(value: fraction).frame(maxWidth: 220)
                    } else { ProgressView().controlSize(.large) }
                    VStack(spacing: 4) {
                        Text(displayName(library.opener.reference?.name ?? "")).font(.headline)
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    Button("Cancel") { library.opener.cancel() }.buttonStyle(.bordered).padding(.top, 4)
                }
                .padding()
            } else {
                ContentUnavailableView("Open a Document", systemImage: "book",
                                       description: Text("Choose a notebook from Dropbox or Recents, or import one from Files."))
            }
        }
        .background(library.opener.displayed != nil ? Color(.secondarySystemBackground) : Color(.systemBackground))
        .task(id: library.reader.page) {
            guard library.opener.displayed != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { pageIndicatorVisible = true }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { pageIndicatorVisible = false }
        }
        .navigationTitle(displayName(library.opener.reference?.name ?? "Reader"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let showLibrary {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Library", systemImage: "sidebar.left", action: showLibrary)
                        .keyboardShortcut("s", modifiers: [.command, .control])
                }
            }
            if library.opener.displayed != nil {
                ToolbarItemGroup(placement: .primaryAction) {
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
                    if let saved = library.opener.metrics.offlineSavedAt {
                        LabeledContent("Opened from", value: "Saved rendering, offline (saved \(saved.formatted(date: .abbreviated, time: .shortened)))")
                    } else if library.opener.metrics.openedFromCache { LabeledContent("Opened from", value: "Saved rendering (unchanged in Dropbox)") }
                    if let seconds = library.opener.metrics.downloadSeconds { LabeledContent("Download", value: String(format: "%.2f s", seconds)) }
                    if let seconds = library.opener.metrics.previewSeconds { LabeledContent("Preview rendering", value: String(format: "%.2f s", seconds)) }
                    if let seconds = library.opener.metrics.recognitionSeconds { LabeledContent("Handwriting recognition", value: String(format: "%.2f s", seconds)) }
                    if let path = library.opener.reference?.path { LabeledContent("Dropbox path", value: path) }
                    Text("Dropbox documents are checked for changes on Open or Reload; unchanged documents reuse a saved rendering. Checking requires a network connection. Imported documents last for this session.").font(.footnote)
                }.navigationTitle("Document Information").toolbar { Button("Done") { showingInfo = false } }
            }.presentationDetents([.medium, .large])
        }
    }
}


extension ReaderScreen {
    /// Progress and notices float over the page instead of pushing it down.
    @ViewBuilder var banners: some View {
        VStack(spacing: 8) {
            if let status = library.opener.status {
                ReaderBanner(symbol: nil) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status).font(.footnote)
                        if let fraction = library.opener.fraction { ProgressView(value: fraction) }
                    }
                } trailing: {
                    Button("Cancel") { library.opener.cancel() }.font(.footnote)
                }
            }
            if let warning = library.opener.warning {
                let offline = library.opener.metrics.offlineSavedAt != nil
                ReaderBanner(symbol: offline ? "wifi.slash" : "exclamationmark.triangle.fill") {
                    Text(warning).font(.footnote)
                } trailing: {
                    if offline { Button("Reload") { library.reload() }.font(.footnote) }
                    else { Button("Retry") { library.opener.retryRecognition() }.font(.footnote) }
                }
            }
            if let error = library.opener.error {
                ReaderBanner(symbol: library.opener.errorIsOffline ? "wifi.slash" : "exclamationmark.triangle.fill") {
                    Text(error).font(.footnote)
                } trailing: {
                    Button("Retry") { library.reload() }.font(.footnote)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
        .frame(maxWidth: 560)
    }
    var pageIndicator: some View {
        Text("\(library.reader.page + 1) of \(library.reader.document?.pageCount ?? 0)")
            .font(.footnote.monospacedDigit().weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
            .opacity(pageIndicatorVisible ? 1 : 0)
            .accessibilityLabel("Page \(library.reader.page + 1) of \(library.reader.document?.pageCount ?? 0)")
            .allowsHitTesting(false)
    }
}

private struct ReaderBanner<Content: View, Trailing: View>: View {
    let symbol: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
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
