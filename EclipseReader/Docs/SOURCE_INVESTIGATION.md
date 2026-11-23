# Source investigation — 20 November 2026

## Observed evidence

The live site was inspected through an actual browser, read-only DOM/source inspection, and ordinary HTTP requests. No login, CAPTCHA solving, anti-bot workarounds or credential sharing was used.

| Check | Observed result |
|---|---|
| Browser home page | Chapter table and featured tiles. Featured predictions/spoilers are separate from the chapter table. |
| HTTP home page | HTTP 200, 313,557 response bytes using `EclipseReader/1.0 (iOS; personal reader)` |
| HTTP chapter 384 | HTTP 200, 288,068 response bytes, `text/html; charset=UTF-8` using the same agent |
| Catalog | 405 table entries; descending publication/story sequence, chapter 386 down to A0 |
| Chapter URLs | Links use `/chapter/berserk-chapter-384/` and corresponding linked chapter paths; the adapter takes URLs from HTML rather than generating them |
| Chapter navigation | Previous/next links and a chapter `<select>` carrying full chapter URLs |
| Decimal/prologue labels | Examples include 364.5, 356.2, 099.005, and A0–P0 |
| Image structure | Chapter 384 has 25 ordered `<img class="pages__img" src="…">` elements |
| Lazy loading | First three `src` images eager; later images use `loading="lazy"` with their actual URL already in `src` |
| Image delivery | HTTPS `cdn.readberserk.com`; observed URLs contain opaque path components that must not be synthesized |
| First image HEAD request | HTTP 200, `image/jpeg`, Content-Length 264,126; used the app agent and chapter Referer, no cookies |
| Browser image dimensions | First three images 1200 × 1694; all three visibly loaded as image resources |
| Mobile inspection | At a 390 × 844 browser viewport, the first page rendered approximately 350 × 494 CSS pixels; viewport meta supports device width |
| Automation policy | `robots.txt` disallows `/wp-admin/`, permits the admin AJAX path and lists XML/RSS sitemaps. It does not disallow the observed chapter paths. |
| Sessions | Ordinary server requests worked without cookies in this environment; this does not prove cookies will never be required on another network/device |
| Site stability | Initial web-search fetch returned 403; a browser home visit also navigated to an ad destination. Later ordinary HTTPS requests succeeded. Access may vary. |
| Volume metadata | Not observed; the UI does not invent it |
| Content permission | No accessible explicit reuse license or dedicated terms link was established from inspected navigation. A contact link led to another manga domain. Robots policy is not permission to redistribute content. |

The adapter never assumes the opaque CDN path or chapter count is permanent. Tests use observed source **metadata only**, not manga images. Complete observed table and image-tag fixtures are included for deterministic native parsing tests. Short excerpt fixtures make regressions easier to inspect.

`source-audit.json` contains SHA-256 hashes of the saved responses and the portable audit result. Raw response pages containing site scripts/advertisements remain in scratch research files, outside the deliverable. The included observed fixtures retain just the table or image tags.

## Adapter behavior

Catalog rows use the first table cell for the chapter label, the second cell for the published date, and the linked chapter URL for identity. A strict chapter-label pattern rejects prediction posts. If no table rows are found, the chapter-page `<option>` list is supported using the observed `value` URLs. Source-defined order is reversed once to produce ascending story order; numeric sorting would mishandle the alphabetic prologue.

Page discovery reads only the class token `pages__img`, resolves the literal `src` against the chapter URL, removes duplicate URLs and preserves DOM order. It accepts HTTPS source/CDN hosts only. Missing or unexpected page URLs fail the chapter rather than dropping a page. It does not treat advertising images as pages. A new image host, changed selector, or unsupported lazy-loading scheme requires a reviewed adapter change.

Native requests use an ephemeral URLSession, no shared browser cookies, an identifying user agent, normal Accept/Referer headers and a redirect allowlist. HTTP 401/403/429 stops native access and offers Website Mode; no automatic request loop is used. HTTP 404/410 reports an unavailable chapter. Timeouts, other statuses and malformed structures are explicit errors. The app does not currently consume sitemap/API endpoints because the observed table is sufficient.

Website Mode uses a WKWebView with the site's own HTML/scripts, cookies and navigation. It does not extract browser-session images into the native reader. Unexpected top-level destinations are not auto-followed in-app; explicitly tapped external HTTP links open in Safari. New-window scripts are not enabled. There are no native-rendering claims for fallback mode, and WKWebView compatibility itself still needs device testing.

## Limits of the investigation

Only chapter 384 was deeply inspected, with catalog metadata from the home page. Every chapter's content was not fetched, and no bulk image downloads were performed. The browser viewport check is a responsive-layout check, not an iPhone/WKWebView test. A HEAD response proves image endpoint reachability, not a full URLSession image-decoding pass. Source accessibility and third-party scripts may change after the recorded date.

Sources: [home/catalog](https://readberserk.com/), [inspected chapter](https://readberserk.com/chapter/berserk-chapter-384/), [robots policy](https://readberserk.com/robots.txt).
