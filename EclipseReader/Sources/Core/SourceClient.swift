import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data
}
public enum HTTPPolicy {
    public static func validate(status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403, 429: throw SourceError.restricted
        case 404, 410: throw SourceError.missingChapter
        default: throw SourceError.unavailable(status)
        }
    }
}

private final class SourceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // ReadBerserk URLs, or any public HTTPS host for manga the user linked.
        let permitted = request.url.map {
            ReadBerserkParser.normalize($0.absoluteString, relativeTo: ReadBerserkParser.home, image: true) != nil || WebLink.publicHTTPS($0)
        } ?? false
        completionHandler(permitted ? request : nil)
    }
}

public actor WebsiteHTTPClient: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration, delegate: SourceRedirectPolicy(), delegateQueue: nil)
    }
    public func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data {
        guard ReadBerserkParser.normalize(url.absoluteString, relativeTo: ReadBerserkParser.home, image: image) != nil || WebLink.publicHTTPS(url)
        else { throw SourceError.insecureURL }
        var request = URLRequest(url: url)
        // Webtoons sends phones a script-built mobile viewer; its desktop pages list every image.
        let desktop = !image && (url.host?.lowercased().hasSuffix("webtoons.com") ?? false)
        request.setValue(desktop
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        let api = url.host?.lowercased().hasPrefix("api.") ?? false
        request.setValue(image ? "image/*" : api ? "application/json" : "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        do {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SourceError.unavailable(0) }
            try HTTPPolicy.validate(status: http.statusCode)
            guard let finalURL = http.url,
                  ReadBerserkParser.normalize(finalURL.absoluteString, relativeTo: url, image: image) != nil || WebLink.publicHTTPS(finalURL)
            else { throw SourceError.insecureURL }
            let mime = (http.mimeType ?? "").lowercased()
            if image && !mime.hasPrefix("image/") {
                // Some image hosts label pictures as generic binary; accept them only if the bytes are an image.
                guard mime == "application/octet-stream" || mime == "binary/octet-stream",
                      let head = try? FileHandle(forReadingFrom: file).read(upToCount: 12),
                      ImageSniffer.isImage(head) else { throw SourceError.invalidImage }
            }
            if !image && !["text/html", "application/xhtml+xml", "application/json", "text/plain"].contains(mime) {
                throw SourceError.unsupportedStructure
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= (image ? 32 * 1024 * 1024 : 4 * 1024 * 1024) else {
                throw image ? SourceError.invalidImage : SourceError.unsupportedStructure
            }
            return try Data(contentsOf: file, options: .mappedIfSafe)
        } catch let error as URLError where error.code == .timedOut { throw SourceError.timeout }
    }
}

extension WebsiteHTTPClient {
    /// Form POST used only for public chapter-list endpoints (Madara themes). Same host rules as fetch.
    public func post(_ url: URL, referer: URL?, body: String?) async throws -> Data {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 EclipseReader/1.0", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.httpBody = (body ?? "").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.unavailable(0) }
        try HTTPPolicy.validate(status: http.statusCode)
        guard data.count <= 8 * 1024 * 1024 else { throw SourceError.unsupportedStructure }
        return data
    }
}

public protocol MangaSource: Sendable {
    func chapters() async throws -> [Chapter]
    func pages(for chapter: Chapter) async throws -> [MangaPage]
}
public struct ReadBerserkSource: MangaSource, Sendable {
    private let http: any HTTPTransport
    public init(http: any HTTPTransport = WebsiteHTTPClient()) { self.http = http }
    public func chapters() async throws -> [Chapter] {
        let data = try await http.fetch(ReadBerserkParser.home, referer: nil, image: false)
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.unsupportedStructure }
        return try ReadBerserkParser.chapters(in: html)
    }
    public func pages(for chapter: Chapter) async throws -> [MangaPage] {
        let data = try await http.fetch(chapter.url, referer: ReadBerserkParser.home, image: false)
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.unsupportedStructure }
        return try ReadBerserkParser.pages(in: html, chapterURL: chapter.url)
    }
}

public actor ImagePipeline {
    public let cache: DiskImageCache
    private let http: any HTTPTransport
    private let localData: (@Sendable (URL) async throws -> Data)?
    public init(cache: DiskImageCache, http: any HTTPTransport = WebsiteHTTPClient(),
                localData: (@Sendable (URL) async throws -> Data)? = nil) {
        self.cache = cache; self.http = http; self.localData = localData
    }
    public func data(for page: MangaPage, chapter: Chapter) async throws -> Data {
        try Task.checkCancellation()
        // Imported books are read from the app's own library folder, never the network or page cache.
        if page.url.scheme == "eclipselib" {
            guard let localData else { throw SourceError.invalidImage }
            return try await localData(page.url)
        }
        if let cached = try? await cache.data(for: page.url) { return cached }
        let data = try await http.fetch(page.url, referer: chapter.url, image: true)
        try Task.checkCancellation()
        // Cache failures do not prevent online reading.
        try? await cache.insert(data, for: page.url)
        return data
    }
    public func prefetch(_ pages: [MangaPage], chapter: Chapter) async {
        // Callers pass only the next two pages. Sequential, encoded bytes only.
        for page in pages.prefix(2) {
            if Task.isCancelled { return }
            _ = try? await data(for: page, chapter: chapter)
        }
    }
}

/// Recognises common image formats from their first bytes.
public enum ImageSniffer {
    public static func isImage(_ head: Data) -> Bool {
        let b = [UInt8](head.prefix(12))
        guard b.count >= 4 else { return false }
        if b[0] == 0xFF && b[1] == 0xD8 { return true }                              // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true } // PNG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true }               // GIF
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 { return true } // WEBP
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true } // AVIF/HEIC
        return false
    }
}
