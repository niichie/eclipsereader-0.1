import XCTest
import SwiftUI
@testable import EclipseReader

/// Runs inside the real app on a simulator: downloads real books and chapters, opens them in the
/// actual reader screens, and waits for pages to appear. Run by the "Device checks" workflow.
@MainActor
final class ReaderChecks: XCTestCase {
    static let books: [(String, String)] = [
        ("Frankenstein (Standard Ebooks)", "https://standardebooks.org/ebooks/mary-shelley/frankenstein/downloads/mary-shelley_frankenstein.epub?source=download"),
        ("Pride and Prejudice (Standard Ebooks)", "https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice/downloads/jane-austen_pride-and-prejudice.epub?source=download"),
        ("Alice (Project Gutenberg mirror, pictures)", "https://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub"),
    ]
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []
    }

    private func model() -> LibraryModel { LibraryModel.current ?? LibraryModel() }

    /// Shows a SwiftUI screen in its own window at a given size, the way the app would.
    private func show<V: View>(_ view: V, size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }
    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += all(type, in: child) }
        return found
    }
    private func labels(in view: UIView) -> [String] {
        var out: [String] = []
        if let label = view.accessibilityLabel, !label.isEmpty { out.append(label) }
        for child in view.subviews { out += labels(in: child) }
        return out
    }
    /// Polls until the condition holds or time runs out.
    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }
    private func attachScreenshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Books

    /// Every page of every section is accounted for: pagination never drops text.
    func testRealBooksTypesetCompletely() async throws {
        let library = model()
        for (name, address) in Self.books {
            let file = try await WebsiteHTTPClient().downloadFile(URL(string: address)!)
            let series = try await library.importBook(file)
            guard let stored = BookLink.file(of: series.url) else { return XCTFail("\(name): no file") }
            let document = try await BookStore.shared.document(stored)
            var images: [String: Data] = [:]
            for section in document.sections {
                for case .image(let path) in section.blocks where images[path] == nil {
                    if let data = await BookStore.shared.image(stored, path: path) { images[path] = data }
                }
            }
            let pictures = images
            for size in [CGSize(width: 330, height: 700), CGSize(width: 250, height: 560), CGSize(width: 470, height: 820)] {
                let start = Date()
                let style = BookStyle(font: .newYork, size: 19, spacing: 1.4, margin: 1, justify: true, theme: .night)
                let book = await Task.detached { BookTypesetter.typeset(document, images: pictures, style: style, pageSize: size) }.value
                let seconds = Date().timeIntervalSince(start)
                print("CHECK|book|\(name)|\(Int(size.width))x\(Int(size.height))|\(book.pages.count) pages|\(String(format: "%.1fs", seconds))")
                XCTAssertGreaterThan(book.pages.count, 40, "\(name) at \(size): too few pages")
                XCTAssertLessThan(seconds, 25, "\(name) at \(size): typesetting too slow")
                for (index, text) in book.sections.enumerated() {
                    let covered = book.pages.filter { $0.section == index }.reduce(0) { $0 + $1.range.length }
                    XCTAssertEqual(covered, text.length, "\(name): section \(index) lost text in pagination")
                }
            }
            XCTAssertFalse((series.summary ?? "").contains("<"), "\(name): description shows HTML tags")
        }
    }

    /// Opens each book in the real reader screen and waits for typeset pages (no endless "Setting type…").
    func testBooksOpenInTheReader() async throws {
        let library = model()
        for (name, address) in Self.books.prefix(2) {
            let file = try await WebsiteHTTPClient().downloadFile(URL(string: address)!)
            let series = try await library.importBook(file)
            for size in [CGSize(width: 390, height: 844), CGSize(width: 300, height: 640)] {
                let window = show(BookReaderView(chapter: series.chapters[0]).environmentObject(library), size: size)
                let opened = await wait(30) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
                attachScreenshot(window, "\(name) \(Int(size.width))pt")
                XCTAssertTrue(opened, "\(name) never showed a page at \(size) (labels: \(labels(in: window).prefix(8)))")
                // Turn a page with the reader's own controls and make sure text follows.
                if opened {
                    NotificationCenter.default.post(name: PageTurnInput.notification, object: nil, userInfo: ["forward": true])
                    try? await Task.sleep(for: .seconds(1))
                    XCTAssertTrue(all(BookPageView.self, in: window).contains { $0.text.length > 0 }, "\(name): blank after turning")
                }
                window.isHidden = true
            }
        }
    }

    // MARK: Manga

    /// A real chapter from each connected site opens in the manga reader and shows its first picture.
    func testChaptersOpenInTheReader() async throws {
        let library = model()
        let sources: [(String, SearchSource, String)] = [
            ("MangaDex", SearchSource(name: "MangaDex", kind: .mangaDex), "Chainsaw Man"),
            ("WeebCentral", SearchSource(name: "WeebCentral", kind: .weebCentral), "Jujutsu Kaisen"),
            ("WEBTOON", SearchSource(name: "WEBTOON", kind: .webtoons), "Tower of God"),
            ("Asura Scans", SearchSource(name: "Asura", kind: .site(URL(string: "https://asurascans.com/comics")!)), "murim login"),
            ("MangaDot", SearchSource(name: "MangaDot", kind: .site(URL(string: "https://mangadot.net/")!)), "Solo Leveling"),
        ]
        for (name, source, query) in sources {
            let hits: [DiscoverItem]
            do { hits = try await GlobalSearch.search(source, query: query) } catch { XCTFail("\(name): search failed: \(error)"); continue }
            guard let hit = hits.first else { XCTFail("\(name): no search results"); continue }
            let found = try await library.inspect(hit.url)
            guard let chapter = found.chapters.first else { XCTFail("\(name): no chapters"); continue }
            let window = show(ReaderView(chapter: chapter).environmentObject(library), size: CGSize(width: 390, height: 844))
            let shown = await wait(30) {
                self.all(UIImageView.self, in: window).contains { ($0.image?.size.width ?? 0) > 200 && !$0.isHidden && $0.alpha > 0 }
            }
            attachScreenshot(window, "\(name) chapter")
            print("CHECK|manga|\(name)|\(shown ? "page shown" : "NO PAGE")|\(chapter.url.absoluteString)")
            XCTAssertTrue(shown, "\(name): \(chapter.url) showed no page")
            window.isHidden = true
        }
    }

    /// Covers on the library home (Discover, Because you read) and search results load as pictures.
    func testCoversLoad() async throws {
        let library = model()
        let items = try await Discover.mangaDex(limit: 4)
        XCTAssertFalse(items.isEmpty)
        for item in items {
            guard let cover = item.cover else { XCTFail("\(item.title): no cover address"); continue }
            let data = try await library.pipeline.data(for: MangaPage(url: cover, label: "Cover"), chapter: Chapter(url: cover, title: "", number: ""))
            XCTAssertNotNil(UIImage(data: data), "\(item.title): cover isn't a picture")
        }
    }

    // MARK: Series with nothing to read

    /// Jujutsu Kaisen on MangaDex only links to the publisher: adding it must bring the chapters from another site.
    func testLicensedMangaDexSeriesIsAddedFromAnotherSite() async throws {
        let library = model()
        var request = URLRequest(url: URL(string: "https://api.mangadex.org/manga?title=Jujutsu%20Kaisen&limit=10&order%5Brelevance%5D=desc")!)
        request.setValue(WebsiteHTTPClient.appAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let list = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        print("CHECK|licensed|MangaDex titles: " + list.compactMap { ($0["attributes"] as? [String: Any]).flatMap(MangaDex.displayTitle) }.joined(separator: " | "))
        let id = try XCTUnwrap(list.first {
            ($0["attributes"] as? [String: Any]).flatMap(MangaDex.displayTitle).map { Discover.sameTitle($0, "Jujutsu Kaisen") } ?? false
        }?["id"] as? String)
        let readableHere = await MangaDex.hasReadableChapters(id, http: WebsiteHTTPClient())
        print("CHECK|licensed|MangaDex readable: \(String(describing: readableHere))")
        guard case .series(let series, _) = try await library.addLink("https://mangadex.org/title/\(id)") else {
            return XCTFail("Jujutsu Kaisen wasn't added as a series")
        }
        print("CHECK|licensed|added from \(series.url.absoluteString)|\(series.chapters.count) chapters|\(library.notice?.text ?? "-")")
        if readableHere == false {
            XCTAssertFalse(series.url.host?.contains("mangadex") ?? true, "a series with nothing to read was added from MangaDex")
        }
        XCTAssertGreaterThan(series.chapters.count, 100)
    }

    /// Discover and "Because you read" only recommend titles MangaDex can actually show.
    func testRecommendationsAreReadable() async throws {
        let http = WebsiteHTTPClient()
        let popular = try await Discover.mangaDex(limit: 12)
        let similar = try await Discover.similar(to: "Vinland Saga", limit: 8)
        print("CHECK|recommend|popular: \(popular.map(\.title).joined(separator: ", "))")
        print("CHECK|recommend|because: \(similar.map(\.title).joined(separator: ", "))")
        XCTAssertFalse(popular.isEmpty)
        for item in popular + similar {
            let readable = await MangaDex.hasReadableChapters(item.id, http: http)
            XCTAssertNotEqual(readable, false, "\(item.title) has nothing to read but was recommended")
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Rapid page turns, a re-layout in the middle of a turn, and a jump: what crashed a few pages into a book.
    /// Kept synchronous on purpose: the page curl runs on the run loop below, with no async test frame
    /// alive around it (an async test frame here tripped XCTest's own task allocator).
    func testBookPagerSurvivesTurnsDuringRelayout() throws {
        let library = model()
        let style = BookStyle(font: .newYork, size: 19, spacing: 1.4, margin: 1, justify: true, theme: .night)
        let books = Holder<(TypesetBook, TypesetBook)>()
        let ready = expectation(description: "book typeset")
        Task { @MainActor in
            defer { ready.fulfill() }
            do {
                let file = try await WebsiteHTTPClient().downloadFile(URL(string: Self.books[0].1)!)
                let series = try await library.importBook(file)
                guard let stored = BookLink.file(of: series.url) else { return }
                let document = try await BookStore.shared.document(stored)
                books.value = (BookTypesetter.typeset(document, images: [:], style: style, pageSize: CGSize(width: 330, height: 700)),
                               BookTypesetter.typeset(document, images: [:], style: style, pageSize: CGSize(width: 330, height: 660)))
            } catch {
                books.failure = "\(error)"
            }
        }
        wait(for: [ready], timeout: 180)
        guard let (first, second) = books.value else { return XCTFail("couldn't open the book: \(books.failure ?? "no file")") }
        let pager = BookPagerController()
        let reported = Counter()
        pager.changed = { _ in reported.count += 1 }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = pager
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        pager.configure(book: first, style: style, insets: UIEdgeInsets(top: 60, left: 30, bottom: 84, right: 30),
                        twoUp: false, curl: true, title: "Frankenstein", page: 0)
        func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        pump(0.3)
        for round in 0..<12 {
            pager.turn(forward: true)
            if round % 3 == 1 {
                // A re-layout arriving mid-turn (the status bar hiding used to do this).
                pager.configure(book: round % 2 == 0 ? first : second, style: style,
                                insets: UIEdgeInsets(top: round % 2 == 0 ? 60 : 40, left: 30, bottom: 84, right: 30),
                                twoUp: false, curl: true, title: "Frankenstein", page: pager.current)
            }
            if round % 4 == 2 { pager.jump(to: pager.current + 3, animated: true) }
            pump(round % 2 == 0 ? 0.06 : 0.45)
        }
        pump(1.5)
        pager.changed = nil
        print("CHECK|pager|turns reported \(reported.count), now on page \(pager.current + 1)")
        XCTAssertGreaterThan(pager.current, 3, "pages didn't advance")
        XCTAssertTrue(all(BookPageView.self, in: window).contains { $0.text.length > 0 }, "blank page after turning")
    }

    /// The whole reader on screen, turning pages while the safe area changes under it, the way hiding
    /// the status bar does. This re-laid out the book mid-turn and crashed a few pages in.
    func testBookReaderTurnsWhileTheStatusBarHides() async throws {
        let library = model()
        let file = try await WebsiteHTTPClient().downloadFile(URL(string: Self.books[1].1)!)
        let series = try await library.importBook(file)
        let host = UIHostingController(rootView: AnyView(BookReaderView(chapter: series.chapters[0]).environmentObject(library)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        let opened = await wait(40) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
        XCTAssertTrue(opened, "the book never opened")
        guard opened else { return }
        let start = Date()
        for round in 0..<24 {
            NotificationCenter.default.post(name: PageTurnInput.notification, object: nil, userInfo: ["forward": true])
            // Status bar hiding and showing: the top safe area shrinks and grows mid-turn.
            host.additionalSafeAreaInsets.top = round % 3 == 0 ? 0 : 20
            try? await Task.sleep(for: .milliseconds(round % 2 == 0 ? 120 : 500))
        }
        try? await Task.sleep(for: .seconds(2))
        let pages = all(BookPageView.self, in: window)
        let folio = pages.first { $0.text.length > 0 }?.folio ?? "?"
        print("CHECK|reader|24 turns with the safe area changing in \(String(format: "%.1fs", Date().timeIntervalSince(start))), now on page \(folio)")
        XCTAssertTrue(pages.contains { $0.text.length > 0 }, "blank after turning")
        XCTAssertGreaterThan(Int(folio) ?? 0, 6, "pages didn't advance")
        attachScreenshot(window, "after turning")
    }
}

/// A reference counter for closures that outlive a test's own frame.
final class Counter { var count = 0 }
final class Holder<T> { var value: T?; var failure: String? }
