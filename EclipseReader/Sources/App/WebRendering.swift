import Foundation
import UIKit
import WebKit

/// Blocks requests to common ad, pop-up and tracking networks in eclipsereader's web views.
/// The native reader never shows ads (it only loads page images); this keeps the in-app
/// browser and background page rendering clean and fast.
@MainActor
enum AdBlock {
    private static var compiled: WKContentRuleList?
    private static var attempted = false
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "googletagservices.com",
        "google-analytics.com", "googletagmanager.com", "adnxs.com", "amazon-adsystem.com", "taboola.com", "outbrain.com",
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "exoclick.com", "exosrv.com", "juicyads.com",
        "trafficjunky.net", "adsterra.com", "adsterratech.com", "hilltopads.net", "clickadu.com", "onclickads.net",
        "onclkds.com", "a-ads.com", "mgid.com", "revcontent.com", "criteo.com", "criteo.net", "pubmatic.com", "rubiconproject.com",
        "openx.net", "scorecardresearch.com", "quantserve.com", "hotjar.com", "yandex.ru", "mc.yandex.ru", "adskeeper.com",
        "bidgear.com", "monetag.com", "galaksion.com", "realsrv.com", "highperformanceformat.com", "profitablegatecpm.com",
    ]
    static let appBanners = [
        "[class*='smartbanner']", "[id*='smartbanner']", "[class*='app-banner']", "[class*='app_banner']", "[class*='AppBanner']",
        "[class*='app-install']", "[class*='app_install']", "[class*='appInstall']", "[class*='app-download']",
        "[class*='app_download']", "[class*='appDownload']", "[class*='open-in-app']", "[class*='openInApp']",
        "[class*='getTheApp']", "[class*='get-the-app']", "[class*='app_promotion']", "[class*='appPromotion']",
    ].joined(separator: ", ")
    static func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        guard !attempted else { return nil }
        attempted = true
        var list = domains.map { domain -> [String: Any] in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]],
                    "action": ["type": "block"]]
        }
        // Cosmetic: hide "get the app" banners and pop-ups that cover the comic.
        list.append(["trigger": ["url-filter": ".*"],
                     "action": ["type": "css-display-none", "selector": appBanners]])
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return nil }
        compiled = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "eclipse-adblock-v2", encodedContentRuleList: json)
        return compiled
    }
}

/// Renders a page the way Safari would, for sites that build their pages with scripts, then hands the
/// finished HTML to the same page/chapter detection. Runs off-screen, scrolls to trigger lazy images,
/// and never solves challenges or logs in: if a site asks for that, the user opens it in the browser.
@MainActor
final class PageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var blocked = false

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // shares sign-ins / site checks passed in the in-app browser
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        super.init()
        webView.navigationDelegate = self
    }

    static func html(for url: URL, timeout: TimeInterval = 25) async throws -> String {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        let renderer = PageRenderer()
        if let rules = await AdBlock.rules() { renderer.webView.configuration.userContentController.add(rules) }
        // Pages only run lazy-loading code while they're in a window: host it invisibly.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        if let window {
            renderer.webView.alpha = 0.01
            renderer.webView.isUserInteractionEnabled = false
            window.insertSubview(renderer.webView, at: 0)
        }
        defer { renderer.webView.removeFromSuperview() }
        return try await renderer.render(url, timeout: timeout)
    }

    private func render(_ url: URL, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        webView.load(URLRequest(url: url))
        try await Task.sleep(for: .milliseconds(800))
        while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        if blocked { throw SourceError.insecureURL }
        // Scroll through the page so lazy-loaded images get their real addresses.
        for step in 1...8 where Date() < deadline {
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight * \(step) / 8); 0")
            try await Task.sleep(for: .milliseconds(350))
        }
        guard let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String, !html.isEmpty else {
            throw SourceError.unsupportedStructure
        }
        let lower = html.lowercased()
        if lower.contains("cf-challenge") || lower.contains("challenge-platform") || lower.contains("just a moment") {
            throw SourceError.restricted
        }
        webView.stopLoading()
        return html
    }

    /// Only public HTTPS pages load in the renderer; no other schemes, no local network.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            let ok = WebLink.publicHTTPS(url)
            if !ok { blocked = true }
            decisionHandler(ok ? .allow : .cancel)
        } else {
            decisionHandler(url.scheme == "https" || url.scheme == "about" ? .allow : .cancel)
        }
    }
}
