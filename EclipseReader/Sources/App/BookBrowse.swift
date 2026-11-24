import SwiftUI

/// Searches the free libraries whose books download straight into the library:
/// Standard Ebooks and Project Gutenberg.
@MainActor
final class BookSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, done([FreeBook]), failed(String) }
    @Published private(set) var standard: Phase = .idle
    @Published private(set) var gutenberg: Phase = .idle
    @Published private(set) var query = ""
    private var tasks: [Task<Void, Never>] = []
    func run(_ text: String) {
        tasks.forEach { $0.cancel() }
        query = text
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { standard = .idle; gutenberg = .idle; return }
        standard = .loading; gutenberg = .loading
        tasks = [
            Task { [weak self] in
                let result: Phase
                do { result = .done(try await FreeBooks.standardEbooks(query: text)) }
                catch { result = .failed(Self.explain(error, site: "Standard Ebooks")) }
                guard let self, self.query == text, !Task.isCancelled else { return }
                self.standard = result
            },
            Task { [weak self] in
                let result: Phase
                do { result = .done(try await FreeBooks.gutenberg(query: text)) }
                catch { result = .failed(Self.explain(error, site: "Project Gutenberg")) }
                guard let self, self.query == text, !Task.isCancelled else { return }
                self.gutenberg = result
            },
        ]
    }
    func cancel() { tasks.forEach { $0.cancel() } }
    /// Nothing found anywhere (and nothing still loading).
    var nothingFound: Bool {
        [standard, gutenberg].allSatisfy { phase in
            switch phase { case .done(let books): books.isEmpty; case .failed: true; default: false }
        }
    }
    static func explain(_ error: Error, site: String) -> String {
        switch error as? SourceError {
        case .unavailable(503): "\(site) is down for maintenance right now. Try again later."
        case .timeout: "\(site) is taking too long to answer. Try again in a minute."
        case .unavailable, .restricted: "\(site) isn’t answering right now. Try again later."
        default: "\(site) couldn’t be searched just now. Check your connection."
        }
    }
}

/// A book cover with title and a line of detail, for search results and carousels.
struct FreeBookCard: View {
    let book: FreeBook
    var busy = false
    var width: CGFloat = 104
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverView(url: book.cover, referer: nil)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
                .overlay {
                    if busy {
                        ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }.clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: book.download != nil ? "arrow.down" : "safari").font(.caption.weight(.heavy)).foregroundStyle(.black)
                        .frame(width: 24, height: 24).background(Eclipse.highlight, in: Circle()).padding(5)
                }
                .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            Text(book.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
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
    @StateObject private var search = BookSearchModel()
    @State private var text = ""
    @State private var popular: [FreeBook] = []
    @State private var busyID: String?
    @State private var message: String?
    /// Libraries whose books download straight into eclipsereader (tap Add book on a book's page).
    /// Lending libraries (Open Library, Internet Archive) are left out: their books are borrow-only.
    static let libraries: [CatalogSite] = [
        SiteCatalog.site("Standard Ebooks", "https://standardebooks.org/ebooks", "Beautifully made free classics", "text.book.closed"),
        SiteCatalog.site("Project Gutenberg", "https://www.gutenberg.org/", "70,000+ free public-domain books", "books.vertical"),
        SiteCatalog.site("Wikisource", "https://en.wikisource.org/", "Public-domain texts · EPUB downloads", "doc.text"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Boring books without pictures").font(.title3.weight(.bold))
                Text("Free books, downloaded straight into your library").font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search free books", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { search.run(text) } }
                if !search.query.isEmpty {
                    Button { text = ""; search.cancel(); search.run("") ; search.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(12).eclipseCard(cornerRadius: 14)
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
            if !search.query.isEmpty {
                BookSearchResults(search: search, busyID: busyID) { open($0) }
            } else if !popular.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Popular free classics").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(popular) { book in
                                Button { open(book) } label: { FreeBookCard(book: book, busy: busyID == book.id) }
                                    .buttonStyle(PressableStyle()).disabled(busyID != nil)
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(Self.libraries) { site in
                    Button { browsing = BrowseTarget(url: site.url) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: site.symbol).foregroundStyle(Eclipse.highlight)
                                .frame(width: 42, height: 42).background(Eclipse.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name).font(.headline).lineLimit(1)
                                Text(site.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            if popular.isEmpty {
                popular = Array(((try? await FreeBooks.standardEbooks()) ?? []).prefix(20))
                if popular.isEmpty { popular = Array(((try? await FreeBooks.gutenberg()) ?? []).prefix(16)) }
            }
        }
    }
    private func open(_ book: FreeBook) {
        message = nil
        if let download = book.download {
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

/// Results from Standard Ebooks and Project Gutenberg, plus matching books already in your library.
struct BookSearchResults: View {
    @EnvironmentObject private var model: LibraryModel
    @ObservedObject var search: BookSearchModel
    var busyID: String?
    let pick: (FreeBook) -> Void
    var body: some View {
        let mine = model.librarySeries.filter { $0.kind == .book && !search.query.isEmpty && $0.title.localizedCaseInsensitiveContains(search.query) }
        VStack(alignment: .leading, spacing: 18) {
            if !mine.isEmpty {
                Text("In your library").font(.headline)
                ForEach(mine) { series in
                    Text("\(series.title)\(series.author.map { " · \($0)" } ?? "")").font(.subheadline)
                }
            }
            row("Standard Ebooks", "Tap to download and keep", search.standard)
            row("Project Gutenberg", "Tap to download and keep", search.gutenberg)
            if search.nothingFound {
                Label {
                    Text("Free libraries only have books that are out of copyright (mostly published before 1930). For newer books, download an EPUB you own in the browser, or import it from Files.")
                } icon: { Image(systemName: "info.circle") }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                                Button { pick(book) } label: { FreeBookCard(book: book, busy: busyID == book.id) }
                                    .buttonStyle(PressableStyle()).disabled(busyID != nil)
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
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    BookSearchResults(search: search, busyID: busyID) { open($0) }
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
    private func open(_ book: FreeBook) {
        message = nil
        if let download = book.download {
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
