import SwiftUI

@MainActor
final class BookSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, done([FreeBook]), failed(String) }
    @Published private(set) var phases: [BookCatalog: Phase] = [:]
    @Published private(set) var query = ""
    private var tasks: [Task<Void, Never>] = []
    func run(_ text: String) {
        cancel()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = term
        phases = [:]
        guard !term.isEmpty else { return }
        for catalog in BookCatalog.allCases {
            phases[catalog] = .loading
            tasks.append(Task { [weak self] in
                let phase: Phase
                do { phase = .done(try await withDeadline(14) { try await catalog.search(term) }) }
                catch { phase = .failed(Self.explain(error, site: catalog.rawValue)) }
                guard !Task.isCancelled, self?.query == term else { return }
                self?.phases[catalog] = phase
            })
        }
    }
    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
    static func explain(_ error: Error, site: String) -> String {
        switch error as? SourceError {
        case .unavailable(503): "\(site) is down for maintenance right now. Try again later."
        case .unsupportedStructure, .restricted: "Open \(site) in the browser to continue this search."
        case .timeout: "\(site) is taking too long to answer. Try again in a minute."
        case .unavailable: "\(site) isn’t answering right now. Try again later."
        default: "\(site) couldn’t be searched just now. Check your connection."
        }
    }
}

/// A book cover with title and a line of detail, for search results and carousels.
struct FreeBookCard: View {
    let book: FreeBook
    var busy = false
    var width: CGFloat = 104
    let open: () -> Void
    let download: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                CoverView(url: book.cover, referer: nil)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
                    .overlay {
                        if busy {
                            ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }.clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
            }.buttonStyle(PressableStyle())
            .overlay(alignment: .bottomTrailing) {
                Button(action: book.download == nil ? open : download) {
                    Image(systemName: book.download != nil ? "arrow.down" : "safari").font(.caption.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 24, height: 24).background(Eclipse.highlight, in: Circle()).padding(5)
                }.buttonStyle(.plain).accessibilityLabel(book.download == nil ? "Open details" : "Download")
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            Button(action: open) {
                Text(book.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            if let author = book.author { Text(author).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            if let detail = book.detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// "Boring books without pictures" in Browse: search free libraries, popular free classics, and library sites.
struct BooksBrowseSection: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var browsing: BrowseTarget?
    @Binding var opened: MangaSeries?
    var externalQuery: String? = nil
    @StateObject private var search = BookSearchModel()
    @State private var text = ""
    @State private var popular: [FreeBook] = []
    @State private var busyID: String?
    @State private var message: String?
    static let libraries = BookCatalog.allCases
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if externalQuery == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Boring books without pictures").font(.title3.weight(.bold))
                    Text("Download public-domain EPUBs or import a book from Files.").font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search free books", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { search.run(text) } }
                    if !search.query.isEmpty {
                        Button { text = ""; search.run("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(12).eclipseCard(cornerRadius: 14)
            }
            BookFileImport { opened = $0 }
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
            if !search.query.isEmpty {
                BookSearchResults(search: search, busyID: busyID, openLocal: { opened = $0 }, browse: { browsing = BrowseTarget(url: $0) }, pick: open)
            } else if !popular.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Popular free classics").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(popular) { book in
                                FreeBookCard(book: book, busy: busyID == book.id, open: { open(book, downloadFile: false) }, download: { open(book, downloadFile: true) })
                                    .disabled(busyID != nil)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
            if externalQuery == nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(Self.libraries, id: \.self) { site in
                        Button { browsing = BrowseTarget(url: site.searchURL(text)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "books.vertical").foregroundStyle(Eclipse.highlight)
                                    .frame(width: 42, height: 42).background(Eclipse.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.rawValue).font(.headline).lineLimit(1)
                                    Text(site.home.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(12).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading).eclipseCard(cornerRadius: 14)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
        .task(id: externalQuery) {
            if let externalQuery { search.run(externalQuery); return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            if popular.isEmpty {
                popular = Array(((try? await FreeBooks.standardEbooks()) ?? []).prefix(20))
                if popular.isEmpty { popular = Array(((try? await FreeBooks.gutenberg()) ?? []).prefix(16)) }
            }
        }
    }
    private func open(_ book: FreeBook, downloadFile: Bool) {
        message = nil
        if !downloadFile, let page = book.page, let download = book.download {
            opened = model.previewBook(book, page: page, download: download)
        } else if downloadFile, let download = book.download {
            busyID = book.id
            Task {
                defer { busyID = nil }
                do { opened = try await model.downloadBook(download) }
                catch { message = "Couldn’t download \(book.title): \(error.localizedDescription)" }
            }
        } else if let page = book.page {
            browsing = BrowseTarget(url: page)
        }
    }
}

/// Each catalog publishes its own results as soon as it answers.
struct BookSearchResults: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var search: BookSearchModel
    var busyID: String?
    let openLocal: (MangaSeries) -> Void
    let browse: (URL) -> Void
    let pick: (FreeBook, Bool) -> Void
    var body: some View {
        let mine = model.librarySeries.filter { $0.kind == .book && !search.query.isEmpty && ($0.title + " " + ($0.author ?? "")).localizedCaseInsensitiveContains(search.query) }
        VStack(alignment: .leading, spacing: 18) {
            if !mine.isEmpty {
                Text("In your library").font(.headline)
                ForEach(mine) { series in
                    Button { openLocal(series) } label: { Text("\(series.title)\(series.author.map { " · \($0)" } ?? "")").font(.subheadline) }
                }
            }
            ForEach(BookCatalog.allCases.sorted { rank($0) < rank($1) }, id: \.self) { catalog in
                let phase = search.phases[catalog] ?? .idle
                if !Self.isFailed(phase) { row(catalog.rawValue, "Tap a cover for details", phase) }
            }
            // Catalogs that couldn't be read: one line, their browser searches in a dropdown.
            let failed = BookCatalog.allCases.filter { Self.isFailed(search.phases[$0] ?? .idle) }
            if !failed.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(failed.count) catalog\(failed.count == 1 ? "" : "s") couldn’t be read")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(failed, id: \.self) { catalog in
                            Button(catalog.rawValue, systemImage: "safari") { browse(catalog.searchURL(search.query)) }
                        }
                    } label: {
                        Label("Try in browser", systemImage: "chevron.down").labelStyle(TrailingIconLabel())
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11).eclipseCard(cornerRadius: 12)
            }
        }
    }
    private static func isFailed(_ phase: BookSearchModel.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
    private func rank(_ catalog: BookCatalog) -> Int {
        if case .done(let books) = search.phases[catalog], !books.isEmpty { return 0 }
        return 1
    }
    @ViewBuilder private func row(_ title: String, _ detail: String, _ phase: BookSearchModel.Phase) -> some View {
        switch phase {
        case .idle: EmptyView()
        case .loading:
            HStack(spacing: 8) { Text(title).font(.headline); ProgressView().controlSize(.mini) }
        case .failed(let reason):
            Text(reason).font(.footnote).foregroundStyle(.secondary)
        case .done(let books):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Text(books.isEmpty ? "No matches" : detail).font(.caption).foregroundStyle(.secondary)
                }
                if !books.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(books) { book in
                                FreeBookCard(book: book, busy: busyID == book.id, open: { pick(book, false) }, download: { pick(book, true) })
                                    .disabled(busyID != nil)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

/// Book search from anywhere (the book quote's "Read" button, the library search box).
struct BookSearchSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = BookSearchModel()
    @State private var text: String
    @State private var busyID: String?
    @State private var opened: MangaSeries?
    @State private var browsing: BrowseTarget?
    @State private var message: String?
    init(query: String) { _text = State(initialValue: query) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Title or author", text: $text).submitLabel(.search).onSubmit { search.run(text) }
                    }
                    .padding(.horizontal, 14).frame(height: 50).eclipseCard(cornerRadius: 14)
                    BookFileImport { opened = $0 }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    BookSearchResults(search: search, busyID: busyID, openLocal: { opened = $0 }, browse: { browsing = BrowseTarget(url: $0) }, pick: open)
                }
                .padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Find a book").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { search.cancel(); dismiss() }.fontWeight(.semibold) }
            .task { if search.query.isEmpty { search.run(text) } }
            .sheet(item: $opened) { series in SeriesSheet(series: series).environmentObject(model) }
            .fullScreenCover(item: $browsing) { target in MangaBrowserView(start: target.url).environmentObject(model) }
        }
        .preferredColorScheme(.dark)
    }
    private func open(_ book: FreeBook, downloadFile: Bool) {
        message = nil
        if !downloadFile, let page = book.page, let download = book.download {
            opened = model.previewBook(book, page: page, download: download)
        } else if downloadFile, let download = book.download {
            busyID = book.id
            Task {
                defer { busyID = nil }
                do { opened = try await model.downloadBook(download) }
                catch { message = "Couldn’t download \(book.title): \(error.localizedDescription)" }
            }
        } else if let page = book.page {
            browsing = BrowseTarget(url: page)
        }
    }
}

private struct BookFileImport: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var choosing = false
    @State private var error: String?
    let opened: (MangaSeries) -> Void
    var body: some View {
        Button("Import book from Files") { choosing = true }
            .fileImporter(isPresented: $choosing, allowedContentTypes: BookLink.types) { result in
                Task {
                    do {
                        let url = try result.get()
                        opened(try await model.importFiles([url], copy: true))
                    } catch let failure as CocoaError where failure.code == .userCancelled {
                        return
                    } catch { self.error = error.localizedDescription }
                }
            }
        if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
    }
}
