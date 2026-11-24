import Foundation
import CryptoKit

/// Downloaded chapters and custom covers. Lives in Application Support, so iOS does not purge it
/// the way it can purge caches. Pages are stored exactly as the website served them (no recompression).
actor OfflineStore {
    static let shared = OfflineStore()

    struct Manifest: Codable, Sendable {
        var chapterID: String
        var title: String
        var files: [String]
        var pageKeys: [String]?
        var bytes: Int64
        var date: Date
    }

    private var manifests: [String: Manifest] = [:]   // keyed by chapter id
    private var loaded = false
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipseReader/Downloads", isDirectory: true)
    }
    private var coverRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipseReader/Covers", isDirectory: true)
    }

    static func key(_ chapterID: String) -> String {
        SHA256.hash(data: Data(chapterID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("chapter.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("partial.json").path) { continue }
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            manifests[manifest.chapterID] = manifest
        }
    }

    func downloadedIDs() -> Set<String> { loadIfNeeded(); return Set(manifests.keys) }
    func totalBytes() -> Int64 { loadIfNeeded(); return manifests.values.reduce(0) { $0 + $1.bytes } }

    /// Pages of a downloaded chapter, served from disk. nil when the chapter is not downloaded.
    func pages(for chapter: Chapter) -> [MangaPage]? {
        loadIfNeeded()
        guard let manifest = manifests[chapter.id], !manifest.files.isEmpty else { return nil }
        let key = Self.key(chapter.id)
        return manifest.files.indices.map { MangaPage(url: URL(string: "eclipselib://offline/\(key)/\($0)")!, label: "Page \($0 + 1)") }
    }

    func begin(_ chapterID: String) throws {
        loadIfNeeded()
        let dir = root.appendingPathComponent(Self.key(chapterID), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
    }
    func resume(_ chapterID: String, pages: [MangaPage]) throws -> [String] {
        loadIfNeeded()
        let folder = root.appendingPathComponent(Self.key(chapterID))
        let marker = folder.appendingPathComponent("partial.json")
        let signature = Self.key(try JSONEncoder().encode(pages.map { $0.url.absoluteString }).base64EncodedString())
        if (try? String(contentsOf: marker, encoding: .utf8)) != signature {
            try begin(chapterID)
            try signature.write(to: marker, atomically: true, encoding: .utf8)
            return []
        }
        var saved: [String] = []
        for index in pages.indices {
            let name = String(format: "%04d.page", index)
            let bytes = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard (bytes ?? 0) > 0 else { break }
            saved.append(name)
        }
        return saved
    }

    func write(_ chapterID: String, index: Int, data: Data) throws -> String {
        let name = String(format: "%04d.page", index)
        try data.write(to: root.appendingPathComponent(Self.key(chapterID)).appendingPathComponent(name), options: .atomic)
        return name
    }
    func finish(_ chapterID: String, title: String, files: [String], pages: [MangaPage]? = nil) throws {
        loadIfNeeded()
        let dir = root.appendingPathComponent(Self.key(chapterID), isDirectory: true)
        let bytes = files.reduce(Int64(0)) { sum, name in
            sum + Int64((try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let manifest = Manifest(chapterID: chapterID, title: title, files: files, pageKeys: pages?.map { Self.key($0.url.absoluteString) }, bytes: bytes, date: Date())
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("chapter.json"), options: .atomic)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("partial.json"))
        manifests[chapterID] = manifest
    }
    func repair(_ chapterID: String, index: Int, page: MangaPage, data: Data) throws {
        loadIfNeeded()
        guard var manifest = manifests[chapterID], manifest.files.indices.contains(index) else { throw SourceError.missingChapter }
        if let keys = manifest.pageKeys, keys[safe: index] != Self.key(page.url.absoluteString) { throw SourceError.unsupportedStructure }
        let dir = root.appendingPathComponent(Self.key(chapterID))
        try data.write(to: dir.appendingPathComponent(manifest.files[index]), options: .atomic)
        manifest.bytes = manifest.files.reduce(0) { total, name in
            total + Int64((try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("chapter.json"), options: .atomic)
        manifests[chapterID] = manifest
    }
    func remove(_ chapterID: String) {
        loadIfNeeded()
        manifests[chapterID] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.key(chapterID)))
    }
    func removeAll() {
        manifests = [:]
        try? FileManager.default.removeItem(at: root)
    }

    /// Saves a cover picked from Photos and returns the address the image pipeline reads it from.
    func saveCover(_ data: Data, seriesID: String) throws -> URL {
        try FileManager.default.createDirectory(at: coverRoot, withIntermediateDirectories: true)
        let name = Self.key(seriesID) + "-" + String(Int(Date().timeIntervalSince1970)) + ".img"
        try data.write(to: coverRoot.appendingPathComponent(name), options: .atomic)
        return URL(string: "eclipselib://cover/\(name)")!
    }

    /// Reads eclipselib://offline/<key>/<index> and eclipselib://cover/<file>.
    func data(_ url: URL) throws -> Data {
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "offline":
            guard parts.count == 2, parts[0].count == 32, parts[0].allSatisfy(\.isHexDigit), let index = Int(parts[1]) else {
                throw SourceError.invalidImage
            }
            let file = root.appendingPathComponent(parts[0]).appendingPathComponent(String(format: "%04d.page", index))
            return try Data(contentsOf: file, options: .mappedIfSafe)
        case "cover":
            guard parts.count == 1, !parts[0].contains(".."), parts[0].hasSuffix(".img") else { throw SourceError.invalidImage }
            return try Data(contentsOf: coverRoot.appendingPathComponent(parts[0]))
        default:
            throw SourceError.invalidImage
        }
    }
}
