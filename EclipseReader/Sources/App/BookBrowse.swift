import SwiftUI

/// Searches free libraries for books: Project Gutenberg (download and keep) and Open Library (borrow or read).
@MainActor
final class BookSearchModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, done([FreeBook]), failed }
    @Published private(set) var gutenberg: Phase = .idle
    @Published private(set) var openLibrary: Phase = .idle
    @Published private(set) var query = ""
    private var tasks: [Task<Void, Never>] = []
    func run(_ text: String) {
        tasks.forEach { $0.cancel() }
        query = text
        gutenberg = .loading; openLibrary = .loading
        tasks = [
            Task { [weak self] in
                let result: Phase
                do { result = .done(try await FreeBooks.gutenberg(query: text)) } catch { result = .failed }
                guard let self, self.query == text, !Task.isCancelled else { return }
                self.gutenberg = result
            },
            Task { [weak self] in
                let result: Phase
                do { result = .done(try await FreeBooks.openLibrary(query: text)) } catch { result = .failed }
                guard let self, self.query == text, !Task.isCancelled else { return }
                self.openLibrary = result
            },
        ]
    }
    func cancel() { tasks.forEach { $0.cancel() } }
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
    static let libraries: [CatalogSite] = [
        SiteCatalog.site("Project Gutenberg", "https://www.gutenberg.org/", "70,000+ free classics · tap Download EPUB", "books.vertical"),
        SiteCatalog.site("Standard Ebooks", "https://standardebooks.org/ebooks", "Beautifully made free classics", "text.book.closed"),
        SiteCatalog.site("Open Library", "https://openlibrary.org/", "Borrow millions of books free", "building.columns"),
        SiteCatalog.site("Internet Archive", "https://archive.org/details/texts", "Free books, magazines and more", "archivebox"),
        SiteCatalog.site("Wikisource", "https://en.wikisource.org/", "Free public-domain texts", "doc.text"),
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
            if popular.isEmpty { popular = Array(((try? await FreeBooks.gutenberg()) ?? []).prefix(16)) }
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

/// Results from Project Gutenberg and Open Library, plus matching books already in your library.
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
            row("Project Gutenberg", "Free to download and keep", search.gutenberg)
            row("Open Library", "Borrow or read free online", search.openLibrary)
        }
    }
    @ViewBuilder private func row(_ title: String, _ detail: String, _ phase: BookSearchModel.Phase) -> some View {
        switch phase {
        case .idle: EmptyView()
        case .loading:
            HStack(spacing: 8) { Text(title).font(.headline); ProgressView().controlSize(.mini) }
        case .failed:
            Text("\(title) didn’t answer.").font(.footnote).foregroundStyle(.secondary)
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
                    Text("Books still under copyright usually aren’t free. Open Library can lend many of them, or import a copy you own from Files.")
                        .font(.footnote).foregroundStyle(.secondary)
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

/// Live pick of the launch: a top-ranked manga from MyAnimeList, or a 4★+ book from Open Library.
@MainActor
final class PickStore: ObservableObject {
    static let shared = PickStore()
    @Published private(set) var manga: Recommendation?
    @Published private(set) var book: Recommendation?
    private var mangaPool: [Recommendation] = []
    private var bookPool: [Recommendation] = []
    private var loadedManga = false, loadedBooks = false
    func loadManga(excluding owned: Set<String>) async {
        guard !loadedManga else { return }
        loadedManga = true
        mangaPool = ((try? await Recommendations.topManga()) ?? []).filter { !owned.contains($0.title.lowercased()) }
        manga = mangaPool.randomElement()
    }
    func loadBooks(excluding owned: Set<String>) async {
        guard !loadedBooks else { return }
        loadedBooks = true
        bookPool = ((try? await Recommendations.topBooks()) ?? []).filter { !owned.contains($0.title.lowercased()) }
        book = bookPool.randomElement()
    }
    func shuffle(book isBook: Bool) {
        if isBook { book = bookPool.filter { $0 != book }.randomElement() ?? book }
        else { manga = mangaPool.filter { $0 != manga }.randomElement() ?? manga }
    }
}

/// The pick card: cover, score, a few lines of synopsis, "Find & read" and another pick.
struct PickCard: View {
    let pick: Recommendation
    let read: () -> Void
    let next: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(url: pick.cover, referer: nil)
                .frame(width: 78, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(pick.isBook ? "BOOK OF THE LAUNCH" : "PICK OF THE LAUNCH").font(.caption2.weight(.heavy)).tracking(1.2)
                        .foregroundStyle(Eclipse.highlight)
                    Text(pick.score).font(.caption2.weight(.heavy)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Eclipse.accent.opacity(0.6), in: Capsule())
                }
                Text(pick.title).font(.headline).lineLimit(2)
                if let detail = pick.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let synopsis = pick.synopsis, !synopsis.isEmpty {
                    Text(synopsis).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Button(action: read) {
                        Label(pick.isBook ? "Find it" : "Find & read", systemImage: "magnifyingglass")
                            .font(.caption.weight(.bold)).padding(.horizontal, 12).frame(height: 30)
                            .background(Eclipse.highlight, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(PressableStyle())
                    Button(action: next) {
                        Image(systemName: "shuffle").font(.caption.weight(.bold))
                            .frame(width: 30, height: 30).background(Color.white.opacity(0.1), in: Circle())
                    }.buttonStyle(PressableStyle()).accessibilityLabel("Another pick")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(Color.white.opacity(0.08), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Close pick")
        }
        .padding(14)
        .background(LinearGradient(colors: [Eclipse.surfaceHigh, Eclipse.surface], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Eclipse.hairline))
    }
}
