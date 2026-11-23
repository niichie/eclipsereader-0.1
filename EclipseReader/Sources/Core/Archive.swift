import Foundation
#if canImport(Compression)
import Compression
#endif

enum BookError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let reason): reason } }
}

/// One imported chapter or volume. Pages are read on demand: archives are indexed, not
/// unpacked, so a 1 GB CBZ costs one copy (or none, when reading from the original).
struct BookManifest: Codable, Sendable {
    enum Format: String, Codable, Sendable { case zip, pdf, files }
    struct Entry: Codable, Sendable {
        var path: String              // zip entry name or file path relative to the root
        var offset: UInt64 = 0        // zip: local header offset
        var compressed: UInt64 = 0
        var size: UInt64 = 0
        var method: UInt16 = 0
        var pdfPage: Int = 0
    }
    var format: Format
    /// Name of the copied file or folder inside the book directory, when copied.
    var copied: String?
    /// Security-scoped bookmark to the original location, when reading in place.
    var bookmark: Data?
    /// Path of the archive/PDF/folder relative to the bookmarked root ("" = the root itself).
    var relative: String = ""
    var entries: [Entry]
}

/// Minimal, bounded ZIP reader: central directory (incl. ZIP64), stored and deflate entries.
enum ZipIndex {
    private static func u16(_ d: Data, _ o: Int) -> UInt16 { d.count >= o + 2 ? UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 : 0 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw BookError.invalid("The archive is damaged or incomplete.") }
        return data
    }

    static func read(_ file: URL, maxEntry: UInt64) throws -> [BookManifest.Entry] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let tailSize = Int(min(length, 65_557))
        guard tailSize >= 22 else { throw BookError.invalid("This is not a valid ZIP/CBZ archive.") }
        let tail = try read(handle, at: length - UInt64(tailSize), count: tailSize)
        var eocd = -1
        var i = tailSize - 22
        while i >= 0 { if u32(tail, i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw BookError.invalid("This is not a valid ZIP/CBZ archive.") }
        var count = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))
        if (count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF), eocd >= 20, u32(tail, eocd - 20) == 0x07064b50 {
            let recordOffset = u64(tail, eocd - 20 + 8)
            let record = try read(handle, at: recordOffset, count: 56)
            guard u32(record, 0) == 0x06064b50 else { throw BookError.invalid("The archive is damaged.") }
            count = u64(record, 32); cdSize = u64(record, 40); cdOffset = u64(record, 48)
        }
        guard count <= 20_000, cdSize <= 32 * 1024 * 1024, cdOffset + cdSize <= length else {
            throw BookError.invalid("The archive is damaged or too large.")
        }
        let cd = try read(handle, at: cdOffset, count: Int(cdSize))
        var entries: [BookManifest.Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x02014b50 else { throw BookError.invalid("The archive is damaged.") }
            let flags = u16(cd, p + 8), method = u16(cd, p + 10)
            var compressed = UInt64(u32(cd, p + 20)), size = UInt64(u32(cd, p + 24))
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            var offset = UInt64(u32(cd, p + 42))
            guard p + 46 + nameLen + extraLen <= cd.count else { throw BookError.invalid("The archive is damaged.") }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // ZIP64 extra field.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let tag = u16(cd, e), len = Int(u16(cd, e + 2))
                if tag == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF { size = u64(cd, q); q += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = u64(cd, q); q += 8 }
                    if offset == 0xFFFF_FFFF { offset = u64(cd, q) }
                }
                e += 4 + len
            }
            p += 46 + nameLen + extraLen + commentLen
            guard !name.hasSuffix("/"), flags & 1 == 0, method == 0 || method == 8 else { continue }
            guard size <= maxEntry, !(method == 8 && compressed > 0 && size / compressed > 1000 && size > 1_000_000) else { continue }
            entries.append(.init(path: name, offset: offset, compressed: compressed, size: size, method: method))
        }
        return entries
    }

    static func extract(_ entry: BookManifest.Entry, from file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try read(handle, at: entry.offset, count: 30)
        guard u32(header, 0) == 0x04034b50 else { throw SourceError.invalidImage }
        let start = entry.offset + 30 + UInt64(u16(header, 26)) + UInt64(u16(header, 28))
        let raw = try read(handle, at: start, count: Int(entry.compressed))
        if entry.method == 0 { return raw }
        #if canImport(Compression)
        guard entry.size > 0 else { throw SourceError.invalidImage }
        var output = Data(count: Int(entry.size))
        let written = output.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(entry.size),
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == Int(entry.size) else { throw SourceError.invalidImage }
        return output
        #else
        throw SourceError.invalidImage
        #endif
    }
}
