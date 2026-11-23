# Architecture and operating constraints

## Layers

`ReadBerserkParser` converts the observed HTML into value models without UI dependencies. `MangaSource` separates source discovery from the library/reader. `HTTPTransport` permits deterministic error/fixture tests without live network access. `WebsiteHTTPClient` handles request policy, safe redirects, status/MIME/size checks and temporary download-file cleanup.

`ImagePipeline` checks the actor-isolated `DiskImageCache` and then requests an individual page. It never requests an entire chapter's images at once. Prefetch receives at most two upcoming pages and processes them sequentially. UI tasks cancel on reuse/disappearance; detached image decoding finishes at most its current bounded decode before cancellation is observed. Simultaneous current-page/prefetch requests can occasionally fetch the same image before either writes its cache entry; in-flight request coalescing is not implemented.

The cache stores encoded bytes with URL identity and creation time in binary property lists. Stable hashed filenames avoid randomized Swift hashes; URL verification prevents hash-collision confusion. Modification times track recent use. Insertion prunes oldest entries to 120 MiB; read-time checks enforce creation-based 24-hour expiry. Launch/background pruning removes stale entries. Cache read/write failures do not prevent network reading. Cached image bytes are removed after a decode failure so Retry can try the network again.

`LibraryModel` owns the on-device Codable `LibraryState`. Atomic JSON saves persist catalog metadata, preferences, explicit read status, recent chapter and page position. Corrupt state gets an attempted backup before creating fresh state. Errors remain visible. An end-of-chapter action explicitly marks a chapter complete; opening the last page alone does not do so.

`ReaderView` manages source loading and progress; `ReaderContainerController` bridges native paging/vertical views to SwiftUI. `PageCanvasController` places the story's earlier page on the right for RTL spreads. Wide images occupy a full canvas; no artwork is cut into halves. `ZoomPageView` uses UIScrollView zooming with ImageIO decoding outside the main actor. Encoded source bytes remain original, while displayed bitmaps cap the longest dimension at 4096 pixels. This avoids huge decoded images while preserving the observed 1200-pixel pages at native resolution.

The horizontal reader uses UIPageViewController's native page curl or scroll transition. Reduce Motion selects scrolling and removes programmatic zoom animation. The vertical reader uses reusable collection-view cells with natural image aspect ratios and corrects estimated heights when images load. Backgrounding saves progress and cancels prefetch; the app has no background modes. Ongoing visible-page URLSession requests are cancellable on view reuse/disappearance and subject to iOS suspension.

## Design choices and limitations

- Minimum iOS 17, iPhone device family, portrait and both landscape orientations. There is no assumed “iPhone Duo” hardware API.
- The brief explicitly defines left-swipe advance, so it is the default despite the different gesture expected by some RTL readers. Story ordering and right-hand spread placement remain RTL; a swipe-convention toggle supports the alternative.
- “Folders” are logical per-chapter entries, not full chapter directories. This preserves chapter organization without requiring downloads.
- Width/height-based spread detection becomes reliable only after metadata or an image reveals dimensions. It is optional and may regroup a visible spread after loading.
- Zoom amount preference is saved; a live transient pan offset or pinch scale is not resumed across app launches. New pages open at the selected fit.
- Page UI testing currently covers library/settings/navigation lifecycle only. Reader gestures, curl, zoom, rotation and Website Mode need the manual/device matrix in VERIFICATION.md.
- No offline chapter downloads, volume guesses, notifications, trackers, analytics, cloud sync, private APIs, JIT or special entitlements.
- Website Mode is explicitly separate, with the original site's scrolling/navigation. It does not update native page-level progress.
- The source HTML parser is intentionally narrow. Malformed structural HTML or changed selectors produce an error, rather than an attempt to scrape arbitrary images.

## Packaging

XcodeGen creates a standard native app and UI-test target. The core is also a dependency-free Swift package, tested separately. The CI workflow builds Release for the device SDK with signing disabled, then verifies arm64 iOS Mach-O metadata and packages the whole built app directory. The resulting ZIP uses the standard `Payload/App.app` IPA layout and executable Unix permissions. It does not contain signing certificates/profiles. Signulous performs its own re-signing later.

The build recipe does not use an App Store export method or require an Apple development team. It cannot run on Windows alone because Apple device SDKs and the iOS linker must run under an authorized macOS/Xcode environment. The repository's macOS runner supplies that environment once connected and run.
