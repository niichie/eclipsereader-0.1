import SwiftUI
import WebKit

/// Unmodified site viewing. No page extraction, cookie export, script injection or challenge solving.
struct WebsiteView: View {
    let url: URL
    /// When set, shows a button that hands the current page to the native reader.
    var onRead: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = WebsiteBrowser()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebsiteSurface(browser: browser, url: url)
                if let error = browser.error {
                    Text(error).font(.subheadline).foregroundStyle(.orange).padding(12)
                }
                HStack {
                    Button { browser.webView.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Spacer()
                    if browser.loading { ProgressView() }
                    Button { browser.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Spacer()
                    if let onRead {
                        Spacer()
                        Button { onRead(browser.webView.url ?? url) } label: { Label("Read here", systemImage: "book") }
                            .accessibilityHint("Opens this page in the eclipsereader page reader")
                    }
                    Spacer()
                    Link("Safari", destination: browser.webView.url ?? url)
                }.padding(16).background(.bar)
            }.navigationTitle(url.host ?? "Website").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(.dark)
    }
}

@MainActor
final class WebsiteBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var error: String?
    @Published var loading = true
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    @Published var title = ""
    /// Bumps whenever the page changes (loads, or a script-driven site swaps its content).
    @Published var pageVersion = 0
    var homeHost: String?
    private var urlObservation: NSKeyValueObservation?
    /// Browse tab: free navigation across public HTTPS sites (search results, links between sites).
    private let openWeb: Bool
    init(openWeb: Bool = false) {
        self.openWeb = openWeb
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self; webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false; webView.backgroundColor = .black
        // Single-page sites change address without a full load; follow those too.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.currentURL != self.webView.url {
                    self.currentURL = self.webView.url
                    self.canGoBack = self.webView.canGoBack; self.canGoForward = self.webView.canGoForward
                    self.pageVersion += 1
                }
            }
        }
    }
    func reload() { error = nil; webView.reload() }
    /// The page exactly as it is showing (after scripts ran and any site check passed).
    func pageHTML() async -> String? {
        try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
    }
    /// Loads the first page once ad and tracker blocking is in place.
    func start(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            if let rules = await AdBlock.rules() { self.webView.configuration.userContentController.add(rules) }
            self.webView.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        currentURL = webView.url; title = webView.title ?? ""
        pageVersion += 1
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    /// Loads an address, or searches for the text when it isn't one.
    func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("."), !trimmed.contains(" "), let url = WebLink.parse(trimmed) {
            webView.load(URLRequest(url: url))
        } else {
            var parts = URLComponents(string: "https://duckduckgo.com/")!
            parts.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = parts.url { webView.load(URLRequest(url: url)) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        loading = false; canGoBack = webView.canGoBack
        let ns = error as NSError
        // Cancelled loads, and links that turned into a download ("frame load interrupted"), aren't errors.
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) { return }
        self.error = error.localizedDescription
    }
    /// Links that open a new window (target="_blank", common for downloads and chapter links) open here instead.
    /// Script pop-ups (ads) are ignored.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           openWeb ? WebLink.publicHTTPS(url) : sameSite(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Subresources remain under WebKit control. Unexpected top-level links stay in Safari.
        if openWeb, navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url {
            // Browse mode: any public HTTPS page; nothing local, no other schemes.
            if WebLink.publicHTTPS(url) || url.scheme == "about" { decisionHandler(.allow) } else { decisionHandler(.cancel) }
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false,
           let url = navigationAction.request.url,
           ReadBerserkParser.normalize(url.absoluteString, relativeTo: ReadBerserkParser.home) == nil,
           !sameSite(url) {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            return
        }
        decisionHandler(.allow)
    }
    /// Top-level navigation may stay on the site the user opened (including subdomains).
    private func sameSite(_ url: URL) -> Bool {
        guard WebLink.publicHTTPS(url), let host = url.host?.lowercased(), let home = homeHost else { return false }
        func root(_ h: String) -> String { h.split(separator: ".").suffix(2).joined(separator: ".") }
        return root(host) == root(home)
    }
    // MARK: Downloads (books and comics from any site land in the library)

    /// Called with the downloaded file once it's saved.
    var downloaded: ((URL) -> Void)?
    @Published var downloading = false
    private var destinations: [ObjectIdentifier: URL] = [:]
    static let downloadable: Set<String> = ["epub", "kepub", "mobi", "azw", "azw3", "prc", "fb2", "txt", "rtf", "docx", "odt", "pdf", "cbz", "zip"]
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let mime = (response.mimeType ?? "").lowercased()
        let ext = ((response.suggestedFilename ?? response.url?.lastPathComponent ?? "") as NSString).pathExtension.lowercased()
        let attachment = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment")
        let bookMime = mime.contains("epub") || mime.contains("mobipocket") || mime.contains("x-mobi") || mime.contains("fictionbook")
        let wanted = bookMime || (Self.downloadable.contains(ext) && (attachment || !navigationResponse.canShowMIMEType || ext != "txt" && ext != "pdf"))
        decisionHandler(navigationResponse.isForMainFrame && wanted ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        downloading = true
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        downloading = true
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename.replacingOccurrences(of: "/", with: "-")
        let target = folder.appendingPathComponent(name)
        destinations[ObjectIdentifier(download)] = target
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        downloading = false
        if let file = destinations.removeValue(forKey: ObjectIdentifier(download)) { downloaded?(file) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloading = false
        destinations.removeValue(forKey: ObjectIdentifier(download))
        self.error = "The download didn’t finish: \(error.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; error = "The website process stopped. Tap Reload to reopen it."
    }
}

struct WebsiteSurface: UIViewRepresentable {
    @ObservedObject var browser: WebsiteBrowser
    let url: URL
    func makeUIView(context: Context) -> WKWebView { browser.homeHost = url.host?.lowercased(); browser.start(url); return browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}
