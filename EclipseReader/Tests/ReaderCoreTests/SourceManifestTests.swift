import XCTest
@testable import ReaderCore

final class SourceManifestTests: XCTestCase {
    /// The file that ships in the app: it must always decode, with unique ids and https addresses.
    func testBundledFileDecodes() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/DefaultSources.json")
        let data = try Data(contentsOf: file)
        let sources = try SourceManifest.decode(data)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(sources.count, (raw?["sources"] as? [Any])?.count, "an entry was skipped (bad address or repeated id)")
        XCTAssertEqual(Set(sources.compactMap(\.bundledID)).count, sources.count)
        XCTAssertTrue(sources.allSatisfy { $0.url.scheme == "https" && $0.category != nil })
        for category in [SourceCategory.manga, .webtoons, .comics, .novels] {
            XCTAssertTrue(sources.contains { $0.category == category }, "no \(category) sources")
        }
    }

    func testBundledReadBerserkSearch() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/DefaultSources.json")
        let sites = try SourceManifest.decode(Data(contentsOf: file))
        let site = try XCTUnwrap(sites.first { $0.bundledID == "readberserk" })
        XCTAssertEqual(site.category, .manga)
        XCTAssertEqual(site.native, true)
        let source = SearchSource(name: site.name, kind: .site(site.url))
        let hits = try await GlobalSearch.search(source, query: "Berserk")
        XCTAssertEqual(hits.map(\.url), [ReadBerserkParser.home])
        let unrelated = try await GlobalSearch.search(source, query: "Xiao Gu Niang")
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testPastedListsKeepNames() {
        let text = """
        # my sources
        Example Novels — examplenovels.com
        [Comic Place](https://comic.example.org/latest)
        https://www.another.example.net/
        plain.example.io, second.example.io
        Example Novels again — https://examplenovels.com/x
        """
        let sites = SourceManifest.parseList(text)
        XCTAssertEqual(sites.map(\.host), ["examplenovels.com", "comic.example.org", "another.example.net", "plain.example.io", "second.example.io"])
        XCTAssertEqual(sites.first?.name, "Example Novels")
        XCTAssertEqual(sites[1].name, "Comic Place")
        XCTAssertEqual(sites[1].url.absoluteString, "https://comic.example.org/latest")
    }
}
