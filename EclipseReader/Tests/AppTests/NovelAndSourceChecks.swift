import XCTest
import SwiftUI
import WebKit
@testable import EclipseReader

/// Novels, sources, sign-in sessions, CBR import and translation plumbing, inside the real app on a simulator.
@MainActor
final class NovelAndSourceChecks: XCTestCase {
    private var windows: [UIWindow] = []
    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []
    }
    private func model() -> LibraryModel { LibraryModel.current ?? LibraryModel() }
    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }
    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += all(type, in: child) }
        return found
    }
    private func show<V: View>(_ view: V) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }

    /// A Syosetu novel: added, opened in the novel reader, and carried into the next chapter by turning past the end.
    func testNovelReadsAndCarriesIntoTheNextChapter() async throws {
        let wasOn = Features.novelsOn
        UserDefaults.standard.set(true, forKey: Features.novelsKey)
        defer { UserDefaults.standard.set(wasOn, forKey: Features.novelsKey) }
        let library = model()
        let series = try await library.addNovel(URL(string: "https://ncode.syosetu.com/n9669bk/")!)
        defer { library.remove(series) }
        XCTAssertEqual(series.kind, .novel)
        XCTAssertGreaterThan(series.chapters.count, 250)
        XCTAssertEqual(series.language, "ja")
        let window = show(ReaderView(chapter: series.chapters[0]).environmentObject(library))
        let opened = await wait(45) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
        XCTAssertTrue(opened, "the first chapter never opened")
        guard opened else { return }
        XCTAssertEqual(library.state.lastChapterID, series.chapters[0].id, "Opening a novel must update the recommendation seed before a page turn")
        print("CHECK|novel|opened \(series.title): \(all(BookPageView.self, in: window).first { $0.text.length > 0 }?.text.string.prefix(30) ?? "")")
        let second = series.chapters[1]
        var moved = false
        let start = Date()
        for _ in 0..<90 {
            NotificationCenter.default.post(name: PageTurnInput.notification, object: nil, userInfo: ["forward": true])
            try? await Task.sleep(for: .milliseconds(400))
            if all(BookPageView.self, in: window).contains(where: { $0.head == second.title && $0.text.length > 0 }) { moved = true; break }
        }
        print("CHECK|novel|into “\(second.title)”: \(moved) after \(String(format: "%.1fs", Date().timeIntervalSince(start)))")
        XCTAssertTrue(moved, "turning past the end didn't carry on into the next chapter")
        XCTAssertEqual(library.state.progress[series.chapters[0].id]?.completed, true, "the first chapter wasn't marked read")
        XCTAssertEqual(library.novelPosition(series.id)?.chapterID, second.id)
    }

    /// Wuxiaworld: a free chapter reads in full; a paid one says it's locked instead of failing.
    func testWuxiaworldFreeAndPaidChapters() async throws {
        let free = try await NovelSource().chapter(URL(string: "https://www.wuxiaworld.com/novel/martial-world/mw-chapter-1")!)
        XCTAssertGreaterThan(free.blocks(base: URL(string: "https://www.wuxiaworld.com/")!).count, 20)
        XCTAssertFalse(free.locked)
        let paid = try await NovelSource().chapter(URL(string: "https://www.wuxiaworld.com/novel/martial-world/mw-chapter-2256")!)
        print("CHECK|wuxiaworld|paid chapter locked=\(paid.locked) paragraphs=\(paid.blocks(base: URL(string: "https://www.wuxiaworld.com/")!).count)")
        XCTAssertTrue(paid.locked)
    }

    /// Bundled destinations appear from the manifest; they can be removed (and stay removed), restored, edited,
    /// and lists of sites can be added.
    func testSourcesComeFromTheManifestAndCanBeEdited() throws {
        let library = model()
        let savedSites = library.state.sites, savedRemoved = library.state.removedBundled
        let wasOn = Features.novelsOn
        UserDefaults.standard.set(true, forKey: Features.novelsKey)
        defer {
            library.state.sites = savedSites; library.state.removedBundled = savedRemoved; library.save()
            UserDefaults.standard.set(wasOn, forKey: Features.novelsKey)
        }
        library.state.sites = []
        library.state.removedBundled = []
        library.seedBundledSources()
        let bundled = Set(LibraryModel.bundledSources.compactMap(\.bundledID))
        XCTAssertGreaterThan(bundled.count, 10)
        XCTAssertEqual(Set(library.sources.compactMap(\.bundledID)), bundled)
        let wuxia = try XCTUnwrap(library.sources.first { $0.bundledID == "wuxiaworld" })
        XCTAssertEqual(wuxia.category, .novels)
        library.removeSource(wuxia)
        library.seedBundledSources()
        XCTAssertFalse(library.sources.contains { $0.bundledID == "wuxiaworld" }, "a removed source came back")
        library.restoreBundledSources()
        XCTAssertTrue(library.sources.contains { $0.bundledID == "wuxiaworld" })
        var mangadex = try XCTUnwrap(library.sources.first { $0.bundledID == "mangadex" })
        mangadex.favorite = true
        mangadex.hidden = true
        library.updateSource(mangadex)
        XCTAssertEqual(library.sources.first { $0.bundledID == "mangadex" }?.favorite, true)
        XCTAssertEqual(library.sources.first { $0.bundledID == "mangadex" }?.hidden, true)
        let added = library.addSources(SourceManifest.parseList("My Novels — mynovels.example.org\nhttps://comics.example.net/"), category: .novels)
        XCTAssertEqual(added, 2)
        XCTAssertTrue(library.isNovel(URL(string: "https://mynovels.example.org/book/some-story")!))
        // A comics source with its own reading style: series added from it start that way.
        var comics = try XCTUnwrap(library.sources.first { $0.host == "comics.example.net" })
        comics.category = .comics
        comics.style = .comic
        library.updateSource(comics)
        let url = URL(string: "https://comics.example.net/series/check")!
        let found = LinkInspection(title: "Check", cover: nil, pages: [],
                                   chapters: [Chapter(url: URL(string: "https://comics.example.net/series/check/1")!, title: "Chapter 1", number: "1")])
        guard case .series(let series, _) = library.commit(url, found) else { return XCTFail("not added") }
        defer { library.remove(series) }
        XCTAssertEqual(library.style(for: series.id), .comic)
        XCTAssertFalse(library.isNovel(url))
        print("CHECK|sources|\(bundled.count) bundled, remove/restore/favourite/hide/list import/style all held")
    }

    /// Sign-ins live in the browser's own store: a session is still there for a new browser, and signing out of one
    /// site removes it.
    func testBrowserSessionPersistsAndSignsOut() async throws {
        let started = Date()
        func step(_ name: String) { print("CHECK|session-time|\(name) at \(String(format: "%.1fs", Date().timeIntervalSince(started)))") }
        let store = SiteSessions.store()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".signin-check.example.com", .path: "/", .name: "session", .value: "check", .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await store.httpCookieStore.setCookie(cookie)
        step("cookie set")
        let site = SavedSite(name: "Check", url: URL(string: "https://www.signin-check.example.com/")!)
        let other = SavedSite(name: "Other", url: URL(string: "https://other.example.org/")!)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let fresh = WKWebView(frame: .zero, configuration: configuration)
        let cookies = await fresh.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "session" && $0.domain.contains("signin-check") }, "the session didn't persist")
        step("read back from a new browser")
        let signedIn = await SiteSessions.hasCookies(for: site)
        let otherSignedIn = await SiteSessions.hasCookies(for: other)
        XCTAssertTrue(signedIn)
        XCTAssertFalse(otherSignedIn)
        step("checked")
        await SiteSessions.signOut(of: site)
        step("signed out")
        let after = await SiteSessions.hasCookies(for: site)
        XCTAssertFalse(after, "signing out left the session")
        print("CHECK|session|persisted for a new browser, signed out cleanly")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the browser's session store was slow to answer")
    }

    /// CBR comics: stored RAR pages import and open; compressed ones explain themselves.
    func testCBRImport() async throws {
        let library = model()
        func png(_ hue: CGFloat) -> [UInt8] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90)).image { context in
                UIColor(hue: hue, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
            }
            return Array(image.pngData()!)
        }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        func entry(_ name: String, _ data: [UInt8], method: UInt8) -> [UInt8] {
            let nameBytes = Array(name.utf8)
            var header: [UInt8] = [0, 0, 0x74] + le16(0x8000) + le16(32 + nameBytes.count)
            header += le32(data.count) + le32(data.count) + [2] + le32(0) + le32(0) + [29, method] + le16(nameBytes.count) + le32(0x20)
            return header + nameBytes + data
        }
        func archive(_ entries: [[UInt8]]) throws -> URL {
            var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00] + [0, 0, 0x73] + le16(0) + le16(13) + [0, 0, 0, 0, 0, 0]
            for e in entries { bytes += e }
            bytes += [0, 0, 0x7B] + le16(0x4000) + le16(7)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Check Comic \(UUID().uuidString.prefix(4)).cbr")
            try Data(bytes).write(to: url)
            return url
        }
        let stored = try archive([entry("pages\\002.png", png(0.6), method: 0x30), entry("pages\\001.png", png(0.1), method: 0x30)])
        let series = try await library.importFiles([stored], copy: true)
        defer { library.remove(series) }
        XCTAssertEqual(series.kind, .local)
        let pages = try await library.pages(for: series.chapters[0])
        XCTAssertEqual(pages.count, 2)
        let first = try await library.pipeline.data(for: pages[0], chapter: series.chapters[0])
        XCTAssertNotNil(UIImage(data: first), "the first page isn't an image")
        let compressed = try archive([entry("001.png", png(0.3), method: 0x33)])
        do {
            _ = try await library.importFiles([compressed], copy: true)
            XCTFail("a compressed RAR imported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("compressed RAR"), error.localizedDescription)
        }
        print("CHECK|cbr|stored pages imported and opened; compressed archive explained")
    }

    /// Translation plumbing for novels: the language is recognised, and translations replace paragraph text in place.
    func testNovelTranslationPlumbing() {
        let blocks: [BookBlock] = [
            .heading(level: 2, runs: [BookRun(text: "プロローグ")]),
            .paragraph(runs: [BookRun(text: "俺は34歳住所不定無職。人生を後悔している真っ最中の小太りブサメンのナイスガイだ。")]),
            .image(path: "https://example.com/a.png"),
            .paragraph(runs: [BookRun(text: "つい三時間ほど前までは住所不定ではない、ただの引きこもりベテランニートだったのだが、")]),
        ]
        XCTAssertEqual(NovelTranslator.language(of: blocks, hint: nil), "ja")
        let translated = NovelTranslator.apply(["0": "Prologue", "1": "I'm 34, homeless and jobless."], to: blocks)
        XCTAssertEqual(NovelTranslator.text(of: translated[0]), "Prologue")
        XCTAssertEqual(NovelTranslator.text(of: translated[1]), "I'm 34, homeless and jobless.")
        XCTAssertEqual(translated[2], blocks[2])
        XCTAssertEqual(NovelTranslator.text(of: translated[3]), NovelTranslator.text(of: blocks[3]))
    }
}
