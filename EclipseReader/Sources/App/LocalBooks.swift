import Foundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Imports manga from Files (including iCloud Drive, USB drives and external SSDs).
/// Supports CBZ/ZIP (stored or deflated, ZIP64), PDF, image files and folders.
/// Original files are never modified or deleted.
actor LocalBooks {
    static let shared = LocalBooks()
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "gif", "avif", "bmp", "tif", "tiff"]
    static let archiveTypes: Set<String> = ["zip", "cbz"]
    private let maxEntry: UInt64 = 64 * 1024 * 1024
    private let maxPages = 5000
    private var manifests: [String: BookManifest] = [:]
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipseReader/Books", isDirectory: true)
    }

    // MARK: Import

    /// Imports the picked items as one series. Several archives, or a folder of archives or
    /// chapter folders, become one series with one chapter per item, in natural order.
    func importSeries(_ picked: [URL], copy: Bool) throws -> MangaSeries {
        guard !picked.isEmpty else { throw BookError.invalid("Nothing was selected.") }
        let scoped = picked.map { $0.startAccessingSecurityScopedResource() }
        defer { for (url, ok) in zip(picked, scoped) where ok { url.stopAccessingSecurityScopedResource() } }
        let seriesID = UUID().uuidString.lowercased()
        var chapters: [Chapter] = []
        var title = picked.count == 1 ? picked[0].deletingPathExtension().lastPathComponent
                                      : picked[0].deletingLastPathComponent().lastPathComponent
        let sorted = picked.sorted { ChapterOrder.natural($0.lastPathComponent, $1.lastPathComponent) }
        let looseImages = sorted.filter { Self.imageTypes.contains($0.pathExtension.lowercased()) }
        if !looseImages.isEmpty {
            // Individually picked images form one chapter. They are always copied.
            let id = try makeBook(files: looseImages, base: nil, rootForBookmark: nil, copy: true)
            chapters.append(chapter(id, title: title, number: 1))
        }
        for item in sorted where !Self.imageTypes.contains(item.pathExtension.lowercased()) {
            let bookmark = copy ? nil : try? item.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if isDirectory(item) {
                let made = try importFolder(item, bookmark: bookmark, copy: copy || bookmark == nil)
                if sorted.count == 1 { title = item.lastPathComponent }
                chapters += made
            } else {
                for (name, id) in try importFile(item, bookmark: bookmark, relative: "", copy: copy || bookmark == nil) {
                    chapters.append(chapter(id, title: name, number: chapters.count + 1))
                }
            }
        }
        guard !chapters.isEmpty else {
            throw BookError.invalid("No manga pages were found. Supported: CBZ, ZIP, PDF, image files and folders of images.")
        }
        if chapters.count > 1 { chapters = chapters.enumerated().map { i, c in Chapter(url: c.url, title: c.title, number: String(i + 1)) } }
        let first = try pages(chapters[0]).first
        return MangaSeries(id: "local-" + seriesID, url: URL(string: "eclipselib://series/\(seriesID)")!, title: title,
                           cover: first?.url, kind: .local, chapters: chapters)
    }

    private func chapter(_ bookID: String, title: String, number: Int) -> Chapter {
        Chapter(url: URL(string: "eclipselib://books/\(bookID)")!, title: title, number: String(number))
    }
    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    private func children(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])
            .sorted { ChapterOrder.natural($0.lastPathComponent, $1.lastPathComponent) }
    }

    /// A folder may hold images (one chapter), chapter subfolders, or archives/PDFs.
    private func importFolder(_ folder: URL, bookmark: Data?, copy: Bool) throws -> [Chapter] {
        let items = try children(folder)
        var result: [Chapter] = []
        let images = items.filter { Self.imageTypes.contains($0.pathExtension.lowercased()) }
        if !images.isEmpty {
            let id = try makeBook(files: images, base: folder, rootForBookmark: bookmark, copy: copy)
            result.append(chapter(id, title: folder.lastPathComponent, number: result.count + 1))
        }
        for item in items where !Self.imageTypes.contains(item.pathExtension.lowercased()) {
            let relative = String(item.path.dropFirst(folder.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if isDirectory(item) {
                let nested = try deepImages(item)
                guard !nested.isEmpty else { continue }
                let id = try makeBook(files: nested, base: folder, rootForBookmark: bookmark, copy: copy)
                result.append(chapter(id, title: item.lastPathComponent, number: result.count + 1))
            } else {
                for (name, id) in try importFile(item, bookmark: bookmark, relative: relative, copy: copy) {
                    result.append(chapter(id, title: name, number: result.count + 1))
                }
            }
        }
        return result
    }
    private func deepImages(_ folder: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where Self.imageTypes.contains(url.pathExtension.lowercased()) {
            found.append(url)
            if found.count > maxPages { throw BookError.invalid("A folder has more than \(maxPages) pages.") }
        }
        return found.sorted { ChapterOrder.natural($0.path, $1.path) }
    }

    /// Returns (chapter title, book id) pairs. A CBZ holding several chapter folders becomes several chapters.
    private func importFile(_ file: URL, bookmark: Data?, relative: String, copy: Bool) throws -> [(String, String)] {
        let ext = file.pathExtension.lowercased()
        let name = file.deletingPathExtension().lastPathComponent
        if ext == "pdf" {
            guard let pdf = CGPDFDocument(file as CFURL), pdf.numberOfPages > 0 else {
                throw BookError.invalid("“\(file.lastPathComponent)” is not a readable PDF (it may be damaged or password-protected).")
            }
            let entries = (1...min(pdf.numberOfPages, maxPages)).map { BookManifest.Entry(path: "", pdfPage: $0) }
            return [(name, try store(BookManifest(format: .pdf, bookmark: copy ? nil : bookmark, relative: relative, entries: entries),
                                     copying: copy ? file : nil))]
        }
        guard Self.archiveTypes.contains(ext) else { return [] }
        let entries = try ZipIndex.read(file, maxEntry: maxEntry)
            .filter { e in
                let parts = e.path.split(separator: "/")
                return !parts.contains { $0.hasPrefix(".") || $0 == "__MACOSX" } &&
                    Self.imageTypes.contains((e.path as NSString).pathExtension.lowercased())
            }
            .sorted { ChapterOrder.natural($0.path, $1.path) }
        guard !entries.isEmpty else { throw BookError.invalid("“\(file.lastPathComponent)” has no images inside.") }
        guard entries.count <= maxPages else { throw BookError.invalid("“\(file.lastPathComponent)” has too many pages.") }
        // Group by folder inside the archive: several folders = several chapters.
        var groups: [(String, [BookManifest.Entry])] = []
        for e in entries {
            let folder = (e.path as NSString).deletingLastPathComponent
            if let i = groups.firstIndex(where: { $0.0 == folder }) { groups[i].1.append(e) } else { groups.append((folder, [e])) }
        }
        if groups.count < 2 { groups = [(name, entries)] }
        var copiedName: String?
        var result: [(String, String)] = []
        for (folder, items) in groups {
            var manifest = BookManifest(format: .zip, bookmark: copy ? nil : bookmark, relative: relative, entries: items)
            if copy, let existing = copiedName {
                // Later chapters of the same archive share the first chapter's copy.
                manifest.copied = "../" + existing
                result.append((groups.count > 1 ? (folder as NSString).lastPathComponent : name, try store(manifest, copying: nil)))
            } else {
                let id = try store(manifest, copying: copy ? file : nil)
                if copy { copiedName = id + "/source" }
                result.append((groups.count > 1 ? (folder as NSString).lastPathComponent : name, id))
            }
        }
        return result
    }

    private func makeBook(files: [URL], base: URL?, rootForBookmark: Data?, copy: Bool) throws -> String {
        guard files.count <= maxPages else { throw BookError.invalid("Too many pages in one chapter.") }
        let id = UUID().uuidString.lowercased()
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries: [BookManifest.Entry] = []
        do {
            if copy {
                let folder = dir.appendingPathComponent("source", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (i, file) in files.enumerated() {
                    try Task.checkCancellation()
                    let name = String(format: "%05d.", i) + file.pathExtension.lowercased()
                    try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
                    entries.append(.init(path: name))
                }
                var manifest = BookManifest(format: .files, entries: entries)
                manifest.copied = "source"
                try write(manifest, id: id)
            } else {
                let basePath = base?.path ?? ""
                entries = files.map { .init(path: String($0.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
                try write(BookManifest(format: .files, bookmark: rootForBookmark, entries: entries), id: id)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return id
    }

    private func store(_ manifest: BookManifest, copying file: URL?) throws -> String {
        let id = UUID().uuidString.lowercased()
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = manifest
        do {
            if let file {
                try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("source"))
                manifest.copied = "source"
            }
            try write(manifest, id: id)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return id
    }
    private func write(_ manifest: BookManifest, id: String) throws {
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(id).appendingPathComponent("book.json"), options: .atomic)
        manifests[id] = manifest
    }

    // MARK: Reading

    private func bookID(_ url: URL) throws -> String {
        guard url.scheme == "eclipselib", url.host == "books", let id = url.pathComponents.dropFirst().first,
              UUID(uuidString: id) != nil else { throw SourceError.insecureURL }
        return id
    }
    private func manifest(_ id: String) throws -> BookManifest {
        if let cached = manifests[id] { return cached }
        let data = try Data(contentsOf: root.appendingPathComponent(id).appendingPathComponent("book.json"))
        let value = try JSONDecoder().decode(BookManifest.self, from: data)
        manifests[id] = value
        return value
    }
    func pages(_ chapter: Chapter) throws -> [MangaPage] {
        let id = try bookID(chapter.url)
        let book = try manifest(id)
        return book.entries.indices.map { MangaPage(url: URL(string: "eclipselib://books/\(id)/\($0)")!, label: "Page \($0 + 1)") }
    }
    /// Deletes the app's own copy/index of a book. Originals are never touched.
    func delete(_ chapter: Chapter) {
        guard let id = try? bookID(chapter.url) else { return }
        manifests[id] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }

    func data(_ url: URL) throws -> Data {
        let id = try bookID(url)
        guard url.pathComponents.count >= 3, let index = Int(url.lastPathComponent) else { throw SourceError.invalidImage }
        let book = try manifest(id)
        guard book.entries.indices.contains(index) else { throw SourceError.invalidImage }
        let entry = book.entries[index]
        return try withSource(book, id: id) { source in
            switch book.format {
            case .files:
                let file = book.copied != nil ? source.appendingPathComponent(entry.path) : source.appendingPathComponent(entry.path)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, UInt64(size) <= maxEntry else { throw SourceError.invalidImage }
                return try Data(contentsOf: file, options: .mappedIfSafe)
            case .zip:
                return try ZipIndex.extract(entry, from: source)
            case .pdf:
                return try Self.renderPDF(source, page: entry.pdfPage)
            }
        }
    }

    /// Resolves where a book's bytes live (the app's copy or the original) and opens access to it.
    private func withSource<T>(_ book: BookManifest, id: String, _ body: (URL) throws -> T) throws -> T {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        if let copied = book.copied { return try body(dir.appendingPathComponent(copied).standardizedFileURL) }
        guard let bookmark = book.bookmark else { throw SourceError.invalidImage }
        var stale = false
        guard let base = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw BookError.invalid("The original file is unavailable. Reconnect the drive or re-import this manga.")
        }
        let ok = base.startAccessingSecurityScopedResource()
        defer { if ok { base.stopAccessingSecurityScopedResource() } }
        let target = book.relative.isEmpty ? base : base.appendingPathComponent(book.relative)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw BookError.invalid("The original file is unavailable. Reconnect the drive or re-import this manga.")
        }
        return try body(target)
    }

    static func renderPDF(_ file: URL, page number: Int) throws -> Data {
        guard let pdf = CGPDFDocument(file as CFURL), let page = pdf.page(at: number) else { throw SourceError.invalidImage }
        let box = page.getBoxRect(.cropBox)
        let swap = page.rotationAngle % 180 != 0
        let width = swap ? box.height : box.width, height = swap ? box.width : box.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw SourceError.invalidImage }
        let scale = min(4, 2800 / max(width, height))
        let w = max(1, Int(width * scale)), h = max(1, Int(height * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw SourceError.invalidImage }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        let data = NSMutableData()
        guard let cg = context.makeImage(),
              let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw SourceError.invalidImage }
        CGImageDestinationAddImage(output, cg, nil)
        guard CGImageDestinationFinalize(output) else { throw SourceError.invalidImage }
        return data as Data
    }
}

