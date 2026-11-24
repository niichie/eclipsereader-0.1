import XCTest
@testable import ReaderCore

final class RarTests: XCTestCase {
    private func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbr")
        try Data(bytes).write(to: url)
        return url
    }
    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }

    /// A RAR 4 archive: a stored page, a compressed page, and a folder.
    func testRar4StoredEntries() throws {
        func file(_ name: String, _ data: [UInt8], method: UInt8, flags: Int = 0x8000) -> [UInt8] {
            let nameBytes = Array(name.utf8)
            let headSize = 32 + nameBytes.count
            var header: [UInt8] = [0, 0, 0x74] + le16(flags) + le16(headSize)
            header += le32(data.count) + le32(data.count) + [2] + le32(0) + le32(0) + [29, method] + le16(nameBytes.count) + le32(0x20)
            return header + nameBytes + data
        }
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        bytes += [0, 0, 0x73] + le16(0) + le16(13) + [0, 0, 0, 0, 0, 0]
        bytes += file("Vol 1\\001.jpg", Array("PAGEONE".utf8), method: 0x30)
        bytes += file("Vol 1\\002.jpg", Array("xx".utf8), method: 0x33)
        bytes += file("Vol 1", [], method: 0x30, flags: 0x80E0)
        bytes += [0, 0, 0x7B] + le16(0x4000) + le16(7)
        let url = try write(bytes)
        XCTAssertTrue(RarIndex.isRar(url))
        let entries = try RarIndex.read(url)
        XCTAssertEqual(entries.map(\.path), ["Vol 1/001.jpg", "Vol 1/002.jpg", "Vol 1"])
        XCTAssertEqual(entries.map(\.stored), [true, false, true])
        XCTAssertTrue(entries[2].directory)
        XCTAssertEqual(String(data: try RarIndex.extract(entries[0], from: url), encoding: .utf8), "PAGEONE")
        XCTAssertThrowsError(try RarIndex.extract(entries[1], from: url))
    }

    /// A RAR 5 archive with one stored page.
    func testRar5StoredEntry() throws {
        func vint(_ v: Int) -> [UInt8] {
            var out: [UInt8] = []; var n = v
            repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
            return out
        }
        func block(_ body: [UInt8], data: [UInt8] = []) -> [UInt8] { [0, 0, 0, 0] + vint(body.count) + body + data }
        let page = Array("RAR5PAGE".utf8)
        let name = Array("01.png".utf8)
        var bytes: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        bytes += block([1, 0, 0])
        bytes += block([2, 0x02] + vint(page.count) + [0] + vint(page.count) + [0] + [0] + [0] + vint(name.count) + name, data: page)
        bytes += block([5, 0, 0])
        let url = try write(bytes)
        let entries = try RarIndex.read(url)
        XCTAssertEqual(entries.map(\.path), ["01.png"])
        XCTAssertTrue(entries[0].stored)
        XCTAssertEqual(try RarIndex.extract(entries[0], from: url), Data(page))
    }

    func testNotRar() throws {
        let url = try write(Array("PK\u{3}\u{4}zip".utf8))
        XCTAssertFalse(RarIndex.isRar(url))
        XCTAssertThrowsError(try RarIndex.read(url))
    }
}
