import Foundation

public struct StateRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url))
    }
    public func save(_ state: LibraryState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

/// Temporary encoded bytes only. No chapter downloads, manga bundles or offline guarantee.
public actor DiskImageCache {
    public let directory: URL
    public let byteLimit: Int
    public let lifetime: TimeInterval
    public init(directory: URL, byteLimit: Int = 120 * 1024 * 1024, lifetime: TimeInterval = 86_400) {
        self.directory = directory; self.byteLimit = max(0, byteLimit); self.lifetime = lifetime
    }
    private func key(_ url: URL) -> URL {
        // Stable FNV-1a filename, not Swift's randomized hash. Full URL also stored in the entry.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".cache")
    }
    private struct Entry: Codable { let url: URL; let created: Date; let bytes: Data }
    public func data(for url: URL, now: Date = Date()) throws -> Data? {
        let file = key(url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file),
              let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.url == url, now.timeIntervalSince(entry.created) <= lifetime else {
            try? FileManager.default.removeItem(at: file); return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        return entry.bytes
    }
    public func insert(_ data: Data, for url: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let encoded = try encoder.encode(Entry(url: url, created: now, bytes: data))
        guard encoded.count <= byteLimit else { return }
        try encoded.write(to: key(url), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: key(url).path)
        try? FileManager.default.setAttributes([.creationDate: now], ofItemAtPath: key(url).path)
        try prune(now: now)
    }
    public func prune(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            .filter { $0.pathExtension == "cache" }
        var entries: [(URL, Int, Date)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            let date = values.contentModificationDate ?? .distantPast
            let created = values.creationDate ?? date
            if now.timeIntervalSince(created) > lifetime { try? FileManager.default.removeItem(at: file) }
            else { entries.append((file, values.fileSize ?? 0, date)) }
        }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, count, _) in entries.sorted(by: { $0.2 < $1.2 }) where size > byteLimit {
            try FileManager.default.removeItem(at: url); size -= count
        }
    }
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "cache" { try FileManager.default.removeItem(at: file) }
    }
    public func remove(_ url: URL) { try? FileManager.default.removeItem(at: key(url)) }
    public func size() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "cache" }.reduce(0) { sum, url in
                sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
    }
}
