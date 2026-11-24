import SwiftUI
import UniformTypeIdentifiers

/// Addresses for books in the library: eclipselib://book/<file> for the book, #<n> for a section.
enum BookLink {
    static func isBook(_ chapter: Chapter) -> Bool { chapter.url.scheme == "eclipselib" && chapter.url.host == "book" }
    static func file(of url: URL) -> String? {
        guard url.scheme == "eclipselib", url.host == "book" else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first
    }
    static func section(of chapter: Chapter) -> Int { Int(chapter.url.fragment ?? "") ?? 0 }
    static func book(_ file: String) -> URL { URL(string: "eclipselib://book/\(file)")! }
    static func section(_ file: String, _ index: Int) -> URL { URL(string: "eclipselib://book/\(file)#\(index)")! }
    /// File types the Files picker offers for books.
    static let types: [UTType] = [.epub, .plainText, .rtf, .html, .pdf]
        + ["mobi", "azw", "azw3", "prc", "kf8", "fb2", "docx", "odt", "xhtml", "md", "kepub"].compactMap { UTType(filenameExtension: $0) }
}

/// Books copied into the app, read on demand (an actor: parsing stays off the main thread).
actor BookStore {
    static let shared = BookStore()
    private let root: URL
    private var cache: [String: BookDocument] = [:]
    private var order: [String] = []
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipseReader/Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func url(_ file: String) -> URL { root.appendingPathComponent(file) }

    /// Copies a book in and reads it once (to check it opens and to learn its title and chapters).
    func importBook(_ source: URL) throws -> (file: String, document: BookDocument) {
        UserDefaults.standard.set(true, forKey: Features.booksKey)
        let ext = source.pathExtension.lowercased()
        guard BookFormat.from(fileExtension: ext) != nil else { throw BookReaderError.unreadable("That file type can't be read as a book.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let file = UUID().uuidString + "." + ext
        try FileManager.default.copyItem(at: source, to: url(file))
        do {
            let document = try read(file)
            return (file, document)
        } catch {
            try? FileManager.default.removeItem(at: url(file))
            throw error
        }
    }
    func document(_ file: String) throws -> BookDocument {
        if let hit = cache[file] { return hit }
        return try read(file)
    }
    private func read(_ file: String) throws -> BookDocument {
        let location = url(file)
        guard let format = BookFormat.from(fileExtension: location.pathExtension) else {
            throw BookReaderError.unreadable("That file type can't be read as a book.")
        }
        let document = format == .rtf ? try Self.readRTF(location) : try BookReader.read(location, format: format)
        guard !document.sections.isEmpty else { throw BookReaderError.unreadable("That book has no readable text.") }
        cache[file] = document
        order.removeAll { $0 == file }
        order.append(file)
        if order.count > 2 { cache[order.removeFirst()] = nil }
        return document
    }
    /// A picture inside a book: an EPUB entry, or an image embedded in the file.
    private var zipEntries: [String: [BookManifest.Entry]] = [:]
    func image(_ file: String, path: String) -> Data? {
        if let embedded = cache[file]?.images[path] { return embedded }
        let ext = url(file).pathExtension.lowercased()
        guard ext == "epub" || ext == "kepub" else { return nil }
        if zipEntries[file] == nil { zipEntries[file] = (try? ZipIndex.read(url(file), maxEntry: 64 * 1024 * 1024)) ?? [] }
        guard let entry = zipEntries[file]?.first(where: { $0.path == path || $0.path.lowercased() == path.lowercased() }) else { return nil }
        return try? ZipIndex.extract(entry, from: url(file))
    }
    func delete(_ file: String) {
        cache[file] = nil
        zipEntries[file] = nil
        try? FileManager.default.removeItem(at: url(file))
    }

    /// RTF through the system importer; bold and italic are kept, paragraphs become blocks.
    private static func readRTF(_ file: URL) throws -> BookDocument {
        let text = try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var blocks: [BookBlock] = []
        let full = text.string as NSString
        var location = 0
        while location < full.length {
            let paragraph = full.paragraphRange(for: NSRange(location: location, length: 0))
            var runs: [BookRun] = []
            text.enumerateAttribute(.font, in: paragraph) { value, range, _ in
                let piece = full.substring(with: range).replacingOccurrences(of: "\n", with: "")
                guard !piece.isEmpty else { return }
                let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                runs.append(BookRun(text: piece, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic)))
            }
            if runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { blocks.append(.paragraph(runs: runs)) }
            location = NSMaxRange(paragraph)
        }
        return BookDocument(title: BookReader.niceName(file.deletingPathExtension().lastPathComponent),
                            sections: MarkupReader.splitByHeadings(blocks))
    }
}

/// A cover drawn for books that have none and can't be found online: the title set in type.
@MainActor
enum GeneratedCover {
    static func make(title: String, author: String?) -> Data? {
        let size = CGSize(width: 600, height: 900)
        let hue = CGFloat(abs(title.hashValue % 360)) / 360
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.32, alpha: 1).cgColor,
                          UIColor(hue: hue, saturation: 0.6, brightness: 0.12, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Thin frame and an eclipse ring, like a cloth binding.
            UIColor(white: 1, alpha: 0.25).setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.stroke(CGRect(x: 36, y: 36, width: size.width - 72, height: size.height - 72))
            UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 0.85).setStroke()
            context.cgContext.setLineWidth(4)
            context.cgContext.strokeEllipse(in: CGRect(x: size.width / 2 - 46, y: 140, width: 92, height: 92))
            let center = NSMutableParagraphStyle(); center.alignment = .center
            let serif = UIFont.systemFont(ofSize: 60, weight: .bold).fontDescriptor.withDesign(.serif)
            let titleFont = UIFont(descriptor: serif ?? UIFont.systemFont(ofSize: 60).fontDescriptor, size: 60)
            (title as NSString).draw(with: CGRect(x: 70, y: 300, width: size.width - 140, height: 360),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: [.font: titleFont, .foregroundColor: UIColor.white, .paragraphStyle: center], context: nil)
            if let author {
                (author.uppercased() as NSString).draw(with: CGRect(x: 70, y: size.height - 170, width: size.width - 140, height: 60),
                                                       options: [.usesLineFragmentOrigin],
                                                       attributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold), .kern: 3,
                                                                    .foregroundColor: UIColor(white: 1, alpha: 0.8), .paragraphStyle: center], context: nil)
            }
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}

extension LibraryModel {
    func previewBook(_ book: FreeBook, page: URL, download: URL) -> MangaSeries {
        if let saved = allSeries.first(where: { $0.bookDownloadURL == download }) { return saved }
        var series = MangaSeries(id: "catalog-" + book.id, url: page, title: book.title, cover: book.cover,
                                 kind: .book, chapters: [], author: book.author)
        series.bookDownloadURL = download
        series.inLibrary = false
        state.series = [series] + allSeries
        save()
        return series
    }

    /// Adds a book file to the library under "Boring books without pictures" (and turns books on).
    func importBook(_ source: URL, addToShelf: Bool = true, downloadURL: URL? = nil) async throws -> MangaSeries {
        let (file, document) = try await BookStore.shared.importBook(source)
        let id = "book-" + (file as NSString).deletingPathExtension
        let chapters = document.sections.enumerated().map { index, section in
            Chapter(url: BookLink.section(file, index),
                    title: section.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Part \(index + 1)",
                    number: String(index + 1))
        }
        var cover: URL?
        if let data = document.cover { cover = try? await OfflineStore.shared.saveCover(LibraryModel.coverShaped(data), seriesID: id) }
        var series = MangaSeries(id: id, url: BookLink.book(file), title: document.title, cover: cover, kind: .book,
                                 chapters: chapters, summary: document.summary, author: document.author)
        if let downloadURL, let saved = allSeries.first(where: { $0.bookDownloadURL == downloadURL }) {
            if !saved.isCatalogBookPreview {
                await BookStore.shared.delete(file)
                return saved
            }
            var downloaded = saved
            downloaded.url = series.url
            downloaded.chapters = chapters
            downloaded.summary = document.summary
            downloaded.cover = saved.cover ?? cover
            state.series = allSeries.map { $0.id == saved.id ? downloaded : $0 }
            save()
            return downloaded
        }
        series.bookDownloadURL = downloadURL
        series.inLibrary = addToShelf
        state.series = [series] + allSeries
        save()
        if cover == nil {
            let title = document.title, author = document.author, isbn = document.isbn
            Task { await findCover(for: id, title: title, author: author, isbn: isbn) }
        }
        return series
    }
    /// Cover art from Open Library or Google Books, else a typeset cover; saved on the device.
    func findCover(for id: String, title: String, author: String?, isbn: String?) async {
        let http = WebsiteHTTPClient()
        var data: Data?
        for url in await BookCovers.candidates(title: title, author: author, isbn: isbn, http: http) {
            if let bytes = try? await http.fetch(url, referer: nil, image: true), bytes.count > 2_000 { data = bytes; break }
        }
        if data == nil { data = GeneratedCover.make(title: title, author: author) }
        guard let data, let saved = try? await OfflineStore.shared.saveCover(data, seriesID: id),
              var list = state.series, let i = list.firstIndex(where: { $0.id == id }), list[i].cover == nil else { return }
        list[i].cover = saved
        state.series = list
        save()
    }
    /// Downloads a free book (Project Gutenberg EPUB) straight into the library.
    /// Downloads a book into the library, trying Project Gutenberg's mirror when gutenberg.org is down.
    func downloadBook(_ url: URL) async throws -> MangaSeries {
        if let saved = allSeries.first(where: { $0.bookDownloadURL == url && !$0.isCatalogBookPreview }) { return saved }
        let client = WebsiteHTTPClient()
        var lastError: Error = SourceError.unavailable(0)
        for candidate in [url] + FreeBooks.mirrors(for: url) {
            do { return try await importBook(try await client.downloadFile(candidate), addToShelf: false, downloadURL: url) }
            catch { lastError = error }
        }
        throw lastError
    }
    func bookPosition(_ seriesID: String) -> BookPosition? { state.bookPositions?[seriesID] }
    func setBookPosition(_ position: BookPosition, for seriesID: String) {
        var map = state.bookPositions ?? [:]
        map[seriesID] = position
        state.bookPositions = map
    }
    var hasBooks: Bool { allSeries.contains { $0.kind == .book } }
}

/// Optional parts of the app.
enum Features {
    /// Normal books (EPUB, Kindle…): off unless chosen, or a book is added.
    static let booksKey = "booksEnabled"
    /// Light novels and web novels: an option (setup, or Settings › Library). The app is a comics reader first.
    static let novelsKey = "novelsEnabled"
    static var novelsOn: Bool { UserDefaults.standard.bool(forKey: novelsKey) }
}
