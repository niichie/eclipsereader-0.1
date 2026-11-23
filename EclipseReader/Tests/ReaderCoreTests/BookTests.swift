import XCTest
@testable import ReaderCore

final class BookTests: XCTestCase {
    func testMarkupKeepsStructureAndStyles() {
        let html = """
        <html><head><title>x</title><style>p{color:red}</style></head><body>
        <h1>Chapter One</h1>
        <p>It was a <i>bright</i> cold day in <b>April</b>,&nbsp;and the clocks&#8212;striking.</p>
        <p class="center">* * *</p>
        <blockquote><p>Quoted line</p></blockquote>
        <ul><li>First</li><li><p>Second</p></li></ul>
        <img src="../Images/map.jpg" alt="map"/>
        </body></html>
        """
        let blocks = MarkupReader.blocks(html, base: "OEBPS/Text/ch1.xhtml")
        XCTAssertEqual(blocks.count, 7)
        guard case .heading(1, let heading) = blocks[0] else { return XCTFail("heading") }
        XCTAssertEqual(heading.map(\.text).joined(), "Chapter One")
        guard case .paragraph(let runs) = blocks[1] else { return XCTFail("paragraph") }
        XCTAssertEqual(runs.map(\.text).joined(), "It was a bright cold day in April,\u{00A0}and the clocks—striking.")
        XCTAssertTrue(runs.contains { $0.italic && $0.text == "bright" })
        XCTAssertTrue(runs.contains { $0.bold && $0.text == "April" })
        guard case .centered = blocks[2] else { return XCTFail("centered") }
        guard case .quote = blocks[3] else { return XCTFail("quote") }
        guard case .listItem(_, "•") = blocks[4] else { return XCTFail("list") }
        guard case .listItem(let second, _) = blocks[5], second.first?.text == "Second" else { return XCTFail("list 2") }
        XCTAssertEqual(blocks[6], .image(path: "OEBPS/Images/map.jpg"))
    }

    func testGutenbergTextJoinsWrappedLinesAndFindsChapters() {
        let text = """
        Header junk
        *** START OF THE PROJECT GUTENBERG EBOOK ***

        CHAPTER I

        It is a truth universally acknowledged, that a single man
        in possession of a good fortune, must be in want of a wife.

        CHAPTER II

        Mr. Bennet was among the earliest.

        *** END OF THE PROJECT GUTENBERG EBOOK ***
        Licence
        """
        let book = PlainTextReader.read(Data(text.utf8), name: "pride_and_prejudice")
        XCTAssertEqual(book.title, "pride and prejudice")
        XCTAssertEqual(book.sections.count, 2)
        XCTAssertEqual(book.sections[0].title, "CHAPTER I")
        guard case .paragraph(let runs) = book.sections[0].blocks[1] else { return XCTFail() }
        XCTAssertTrue(runs[0].text.hasPrefix("It is a truth universally acknowledged, that a single man in possession"))
    }

    func testFictionBook() throws {
        let fb2 = """
        <?xml version="1.0" encoding="utf-8"?><FictionBook><description><title-info><author><first-name>Ivan</first-name><last-name>Petrov</last-name></author><book-title>Snow</book-title></title-info></description>
        <body><section><title><p>One</p></title><p>First <emphasis>soft</emphasis> line.</p></section><section><title><p>Two</p></title><p>Second.</p></section></body></FictionBook>
        """
        let book = try FB2Reader.read(Data(fb2.utf8), name: "snow")
        XCTAssertEqual(book.title, "Snow")
        XCTAssertEqual(book.author, "Ivan Petrov")
        XCTAssertEqual(book.sections.map(\.title), ["One", "Two"])
    }

    func testPalmDOCDecompression() {
        // "aaaaaa": literal 'a', then a back-reference (distance 1, length 5).
        let pair = (1 << 3) | (5 - 3)
        let compressed: [UInt8] = [0x61, UInt8(0x80 | (pair >> 8)), UInt8(pair & 0xFF), 0xC0 ^ 0x80 | 0xC0]
        let out = MOBIReader.palmDOC(compressed)
        XCTAssertEqual(String(bytes: out.prefix(6), encoding: .ascii), "aaaaaa")
        XCTAssertEqual(MOBIReader.trailingSize([1, 2, 3, 0x81], flags: 0b10), 1)
    }

    func testEPUBFromAZip() throws {
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", #"<container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#),
            ("OEBPS/content.opf", """
            <package><metadata><dc:title>Red Rising</dc:title><dc:creator>Pierce Brown</dc:creator><dc:identifier>urn:isbn:978-0-345-53978-6</dc:identifier></metadata>
            <manifest><item id="c1" href="Text/one.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
            """),
            ("OEBPS/nav.xhtml", #"<nav epub:type="toc"><ol><li><a href="Text/one.xhtml">Part I: Slave</a></li><li><a href="Text/two.xhtml#x">Part II: Servant</a></li></ol></nav>"#),
            ("OEBPS/Text/one.xhtml", "<html><body><p>The first thing you should know about me is I am my father's son.</p></body></html>"),
            ("OEBPS/Text/two.xhtml", "<html><body><h1>2</h1><p>Second part.</p></body></html>"),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).epub")
        try Self.storedZip(files).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try BookReader.read(url, format: .epub)
        XCTAssertEqual(book.title, "Red Rising")
        XCTAssertEqual(book.author, "Pierce Brown")
        XCTAssertEqual(book.isbn, "9780345539786")
        XCTAssertEqual(book.sections.map(\.title), ["Part I: Slave", "Part II: Servant"])
    }

    /// A ZIP with uncompressed entries, enough for the EPUB reader.
    static func storedZip(_ files: [(String, String)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, text) in files {
            let body = [UInt8](text.utf8), path = [UInt8](name.utf8)
            let offset = out.count
            out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(body.count) + le32(body.count)
                + le16(path.count) + le16(0) + path + body
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(body.count) + le32(body.count)
                + le16(path.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + path
        }
        let start = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(start) + le16(0)
        return Data(out)
    }
}
