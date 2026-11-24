import Foundation

/// Reads the table of contents of RAR archives (RAR 4 and RAR 5), the format behind most CBR comics, and extracts
/// entries stored without compression (common for comics, whose images are already compressed). Compressed or
/// password-protected entries are reported so the app can say so; they are never guessed at.
public enum RarIndex {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let offset: UInt64
        public let size: UInt64
        /// Stored as-is (no RAR compression), so it can be read straight out of the file.
        public let stored: Bool
        public let directory: Bool
        public let encrypted: Bool
    }
    public enum Failure: Error, LocalizedError, Equatable {
        case notRar, damaged, encrypted
        public var errorDescription: String? {
            switch self {
            case .notRar: "That file isn’t a RAR archive."
            case .damaged: "That RAR archive is damaged or incomplete."
            case .encrypted: "That RAR archive is password-protected."
            }
        }
    }
    static let rar4 = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
    static let rar5 = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])

    public static func isRar(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8) else { return false }
        return head.starts(with: rar4) || head.starts(with: rar5)
    }

    public static func read(_ url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 8) ?? Data()
        if head.starts(with: rar5) { return try readRar5(handle, length: length) }
        if head.starts(with: rar4) { return try readRar4(handle, length: length) }
        throw Failure.notRar
    }

    public static func extract(_ entry: Entry, from url: URL, maxSize: UInt64 = 64 * 1024 * 1024) throws -> Data {
        guard entry.stored, !entry.encrypted, entry.size <= maxSize else { throw Failure.damaged }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        let data = try handle.read(upToCount: Int(entry.size)) ?? Data()
        guard UInt64(data.count) == entry.size else { throw Failure.damaged }
        return data
    }

    // MARK: Format details

    static func at(_ handle: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }
    static func u16(_ d: Data, _ i: Int) -> UInt64 { i + 1 < d.count ? UInt64(d[d.startIndex + i]) | UInt64(d[d.startIndex + i + 1]) << 8 : 0 }
    static func u32(_ d: Data, _ i: Int) -> UInt64 { i + 3 < d.count ? u16(d, i) | u16(d, i + 2) << 16 : 0 }
    static func name(_ bytes: Data) -> String {
        // RAR 4 Unicode names put an ASCII form first, ended by a zero byte.
        let plain = bytes.prefix { $0 != 0 }
        let text = String(data: plain, encoding: .utf8) ?? String(data: plain, encoding: .isoLatin1) ?? ""
        return text.replacingOccurrences(of: "\\", with: "/")
    }

    static func readRar4(_ handle: FileHandle, length: UInt64) throws -> [Entry] {
        var entries: [Entry] = []
        var position: UInt64 = 7
        while position + 7 <= length {
            let base = try at(handle, position, 7)
            guard base.count == 7 else { break }
            let type = base[base.startIndex + 2]
            let flags = u16(base, 3)
            let headSize = u16(base, 5)
            guard headSize >= 7 else { throw Failure.damaged }
            var dataSize: UInt64 = 0
            switch type {
            case 0x73:
                // Archive header: encrypted headers mean nothing can be listed without the password.
                if flags & 0x0080 != 0 { throw Failure.encrypted }
            case 0x74:
                let header = try at(handle, position, Int(headSize))
                guard header.count >= 32 else { throw Failure.damaged }
                var packed = u32(header, 7)
                let method = header[header.startIndex + 25]
                let nameSize = Int(u16(header, 26))
                var nameStart = 32
                if flags & 0x0100 != 0 { packed |= u32(header, 32) << 32; nameStart = 40 }
                guard nameStart + nameSize <= header.count else { throw Failure.damaged }
                let path = name(header.subdata(in: (header.startIndex + nameStart)..<(header.startIndex + nameStart + nameSize)))
                // Split across volumes (flags 0x01/0x02) can't be read from this file alone.
                let split = flags & 0x0003 != 0
                entries.append(Entry(path: path, offset: position + headSize, size: packed, stored: method == 0x30 && !split,
                                     directory: flags & 0x00E0 == 0x00E0, encrypted: flags & 0x0004 != 0))
                dataSize = packed
            case 0x7B:
                return entries
            default:
                if flags & 0x8000 != 0 {
                    let added = try at(handle, position + 7, 4)
                    dataSize = u32(added, 0)
                }
            }
            position += headSize + dataSize
        }
        return entries
    }

    /// RAR 5 numbers: 7 bits per byte, low bits first, high bit set while more follow.
    static func vint(_ d: Data, _ i: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < d.count, shift < 64 {
            let byte = d[d.startIndex + i]
            i += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.damaged
    }

    static func readRar5(_ handle: FileHandle, length: UInt64) throws -> [Entry] {
        var entries: [Entry] = []
        var position: UInt64 = 8
        while position + 5 < length {
            let start = try at(handle, position, 14)
            var i = 4
            let headerSize = try vint(start, &i)
            guard headerSize > 0, headerSize < 4 * 1024 * 1024 else { throw Failure.damaged }
            let headerStart = position + UInt64(i)
            let header = try at(handle, headerStart, Int(headerSize))
            guard UInt64(header.count) == headerSize else { throw Failure.damaged }
            var j = 0
            let type = try vint(header, &j)
            let flags = try vint(header, &j)
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x01 != 0 { extraSize = try vint(header, &j) }
            if flags & 0x02 != 0 { dataSize = try vint(header, &j) }
            switch type {
            case 2:
                let fileFlags = try vint(header, &j)
                _ = try vint(header, &j)   // unpacked size
                _ = try vint(header, &j)   // attributes
                if fileFlags & 0x02 != 0 { j += 4 }   // modification time
                if fileFlags & 0x04 != 0 { j += 4 }   // data CRC32
                let compression = try vint(header, &j)
                _ = try vint(header, &j)   // host OS
                let nameLength = try Int(vint(header, &j))
                guard j + nameLength <= header.count else { throw Failure.damaged }
                let path = name(header.subdata(in: (header.startIndex + j)..<(header.startIndex + j + nameLength)))
                // Extra records: type 1 is file encryption.
                var encrypted = false
                if extraSize > 0, extraSize <= headerSize {
                    var k = Int(headerSize - extraSize)
                    while k < header.count {
                        let size = try vint(header, &k)
                        let recordStart = k
                        let recordType = try vint(header, &k)
                        if recordType == 1 { encrypted = true }
                        k = recordStart + Int(size)
                    }
                }
                let method = (compression >> 7) & 0x07
                let split = flags & 0x18 != 0   // data continues from or into another volume
                entries.append(Entry(path: path, offset: headerStart + headerSize, size: dataSize, stored: method == 0 && !split,
                                     directory: fileFlags & 0x01 != 0, encrypted: encrypted))
            case 4:
                throw Failure.encrypted
            case 5:
                return entries
            default:
                break
            }
            position = headerStart + headerSize + dataSize
        }
        return entries
    }
}
