import SwiftUI
import PDFKit

private struct PDFReaderView: UIViewRepresentable {
    let model: ReaderModel
    func makeUIView(context: Context) -> PDFView { model.view }
    func updateUIView(_ view: PDFView, context: Context) {}
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
    @State private var finding = false
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
                    .overlay(alignment: .bottom) {
                        if finding { FindBar(library: library, close: { finding = false }).transition(.move(edge: .bottom).combined(with: .opacity)) }
                        else { pageIndicator }
                    }
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
                                       description: Text("Choose a notebook from Dropbox, Favorites or Recents."))
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
                    BookmarkAction(library: library)
                    Button("Search", systemImage: "magnifyingglass") { withAnimation(.snappy) { finding = true } }.keyboardShortcut("f", modifiers: .command)
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
        // The inspector stays open beside the page; the sheets cover it, so choosing a page closes them.
        .inspector(isPresented: $inspectorVisible) { PagesPanel(library: library, navigated: {}).inspectorColumnWidth(min: 220, ideal: 280, max: 400) }
        .sheet(isPresented: $showingPages) {
            NavigationStack {
                PagesPanel(library: library, navigated: { showingPages = false })
                    .navigationTitle("Pages and Titles").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { showingPages = false } }
            }
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
                    Text("Dropbox documents are checked for changes on Open or Reload; unchanged documents reuse a saved rendering. Checking requires a network connection. Documents opened from other apps last for this session.").font(.footnote)
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

/// Stars or unstars the page on screen; favorites list bookmarked pages by title.
private struct BookmarkAction: View {
    @Bindable var library: MobileLibrary
    var body: some View {
        if let reference = library.opener.reference, reference.source == .dropbox {
            let starred = library.favorites.isBookmarked(reference, page: library.reader.page)
            Button(starred ? "Remove from Favorites" : "Add to Favorites", systemImage: starred ? "star.fill" : "star") {
                library.toggleBookmark()
            }
        }
    }
}

private struct PagesPanel: View {
    @Bindable var library: MobileLibrary
    /// Called after jumping to a page, so a sheet can get out of the way.
    let navigated: () -> Void
    @State private var titles = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Navigation", selection: $titles) { Text("Pages").tag(false); Text("Titles").tag(true) }.pickerStyle(.segmented).padding()
            if titles {
                if library.opener.recognizing { Text("Title labels appear after handwriting recognition finishes.").font(.caption).padding() }
                List(library.reader.titles) { title in
                    Button { library.reader.go(to: title.page); navigated() } label: {
                        HStack {
                            Text(title.label).padding(.leading, CGFloat(title.depth) * 12)
                            Spacer()
                            Text("\(title.page + 1)").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                }.overlay { if library.reader.titles.isEmpty { ContentUnavailableView("No titles yet", systemImage: "list.bullet") } }
            } else { PageGrid(library: library, navigated: navigated) }
        }
    }
}

/// Every page at the same size in two columns: about four pages at a time on iPhone, still legible.
private struct PageGrid: View {
    @Bindable var library: MobileLibrary
    let navigated: () -> Void
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)]
    var body: some View {
        let reader = library.reader
        let count = reader.document?.pageCount ?? 0
        let bookmarked = library.opener.reference.map { library.favorites.bookmarkedPages($0) } ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(0..<count, id: \.self) { index in
                        PageCell(index: index, url: library.opener.displayed?.url, aspect: aspect(index),
                                 title: titleOnPage(index), current: index == reader.page, bookmarked: bookmarked.contains(index)) {
                            reader.go(to: index); navigated()
                        }
                        .id(index)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .onAppear { proxy.scrollTo(reader.page, anchor: .center) }
        }
    }
    private func aspect(_ index: Int) -> CGFloat {
        guard let bounds = library.reader.document?.page(at: index)?.bounds(for: .mediaBox), bounds.height > 0 else { return 3.0 / 4.0 }
        return bounds.width / bounds.height
    }
    /// Only titles written on the page itself; the grid shows where each section starts.
    private func titleOnPage(_ index: Int) -> String? {
        library.reader.titles.filter { $0.page == index }.min { $0.depth < $1.depth }?.label
    }
}

private struct PageCell: View {
    let index: Int
    let url: URL?
    let aspect: CGFloat
    let title: String?
    let current: Bool
    let bookmarked: Bool
    let action: () -> Void
    @State private var image: UIImage?
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color.white
                    if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(current ? Color.accentColor : Color(.separator), lineWidth: current ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if bookmarked {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                            .padding(5).background(.regularMaterial, in: Circle()).padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                VStack(spacing: 1) {
                    Text("\(index + 1)").font(.caption.monospacedDigit().weight(current ? .semibold : .regular))
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                    if let title { Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.map { "Page \(index + 1), \($0)" } ?? "Page \(index + 1)")
        .accessibilityAddTraits(current ? .isSelected : [])
        // Keeps the previous image while a newer rendering of the same page loads.
        .task(id: url) {
            guard let url else { return }
            if let rendered = await PageThumbnailRenderer.shared.image(index, in: url), !Task.isCancelled { image = rendered }
        }
    }
}

/// A browser-style find bar over the bottom of the page: type to jump to the first match, then step
/// through the rest with the arrows, Return, or Command-G and Shift-Command-G.
private struct FindBar: View {
    @Bindable var library: MobileLibrary
    let close: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        @Bindable var reader = library.reader
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this document", text: $reader.query)
                        .focused($focused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { reader.next(); focused = true }
                    if !reader.query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { reader.query = "" }
                            .labelStyle(.iconOnly).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color(.tertiarySystemFill), in: Capsule())
                Button("Done", action: close)
                    .fontWeight(.semibold)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 4) {
                Text(status).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("Match Count")
                Spacer(minLength: 8)
                Button("Previous Match", systemImage: "chevron.up") { reader.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Next Match", systemImage: "chevron.down") { reader.next() }
                    .keyboardShortcut("g", modifiers: .command)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(reader.results.isEmpty)
            .font(.body.weight(.semibold))
            .frame(minHeight: 28)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: 560)
        .onAppear {
            focused = true
            // The term survives closing the bar; find it again on reopening.
            reader.findActive = true
            reader.search()
        }
        .onDisappear { reader.endFind() }
        .onChange(of: reader.query) { _, _ in reader.search() }
    }
    private var status: String {
        let reader = library.reader
        if reader.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return library.opener.recognizing ? "Handwriting is still being recognized" : ""
        }
        if reader.results.isEmpty { return reader.searching ? "Searching…" : "No matches" }
        let count = "\(reader.results.count)\(reader.searching ? "…" : "")"
        var text = "\((reader.current ?? 0) + 1) of \(count) \(reader.results.count == 1 && !reader.searching ? "match" : "matches")"
        if let page = reader.currentMatchPage { text += " · Page \(page + 1)" }
        if library.opener.recognizing { text += " · partial" }
        return text
    }
}
