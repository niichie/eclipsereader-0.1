# Handoff: eclipsereader

Sideload-only iOS reader for manga, manhwa, manhua, webtoons and comics first. Light novels and normal books are opt-in.
It runs on iPhone, iPad and the iPhone Duo (folded and unfolded). The model is Mihon: the app ships no piracy sources, and people bring their own.
The owner wants autonomous work with no regressions: verify everything in CI before calling it done.

Repo: `niichie/eclipsereader-0.1`. The app lives in `EclipseReader/`.

## How to build and verify

There is no local toolchain assumption. Everything is checked through GitHub Actions on the `xcode-27` runner (Xcode 27.2, iOS 27 SDK).

| Workflow | When | What it does |
|---|---|---|
| `main.yml` (“Build eclipsereader IPA”) | Every push; `v*` tags | Runs the Core tests (`swift test`, SwiftPM package `ReaderCore`), then the xcodegen project, then the unsigned IPA artifact `EclipseReader-unsigned-IPA`. A `v*` tag also publishes a GitHub Release. |
| `probe.yml` (“Probe sources”) | Manual; input `filter` | Runs `LiveProbeTests` with `LIVE_PROBE=1` against the live sites. Output lines are `PROBE\|OK/FAIL\|…` and `DUMP\|…`. |
| `device-checks.yml` (“Device checks”) | Manual; input `only` (comma-separated `-only-testing` ids) | Runs the hosted app tests (`EclipseReaderAppTests`) on an iPhone simulator. On failure it prints the error grep, the log tail and parsed `.ips` crash reports. |

Useful commands. GraphQL is blocked in some sandboxes, so use REST:
```sh
gh api repos/niichie/eclipsereader-0.1/actions/workflows/probe.yml/dispatches -f ref=main -f "inputs[filter]=testNovelSources"
gh api repos/niichie/eclipsereader-0.1/actions/workflows/device-checks.yml/dispatches -f ref=main -f "inputs[only]=EclipseReaderAppTests/NovelAndSourceChecks"
gh api repos/niichie/eclipsereader-0.1/actions/jobs/<JOB_ID>/logs | grep -E "CHECK\||PROBE\||error: |Test Case"
```
Artifacts can't always be downloaded from sandboxes, so read job logs instead.

Current state:
- `main` is green at `f1b2d99`: 131 Core tests, and the IPA builds.
- The full device suite passes: `ReaderChecks` (9) and `NovelAndSourceChecks` (6).
- The novel probes pass.

## Layout

```
EclipseReader/
  project.json          xcodegen spec (targets: EclipseReader, EclipseReaderAppTests [hosted], EclipseReaderUITests)
  Package.swift         SwiftPM package "ReaderCore" = Sources/Core only (for fast `swift test`)
  Resources/            Assets, Info.plist, DefaultSources.json (bundled source manifest)
  Sources/Core/         No UI. Site reading, parsing, models, search, books, novels, RAR, AniList, quotes
  Sources/App/          SwiftUI/UIKit app. Library, readers, browser, settings
  Tests/ReaderCoreTests SwiftPM tests (import ReaderCore). LiveProbeTests only run with LIVE_PROBE=1
  Tests/AppTests        Hosted simulator checks (import EclipseReader). Real network, real reader screens
  Tests/AppUITests      UI tests (launch arg --ui-testing)
```

Important: the app target compiles Core and App together as one module, `EclipseReader`. Never declare the same name in both. For example, `Array[safe:]` lives only in `Core/LaunchQuotes.swift`, and `LibraryModel.previous(before:)` already exists. Core tests import `ReaderCore`; app tests import `EclipseReader`.

Swift 6 strict concurrency is on. `LibraryModel` is a main-actor `ObservableObject`. WebKit is used on the main actor.

## Key files

### Core

| File | What it holds |
|---|---|
| `Models.swift` | `MangaSeries` (see below), `Chapter`, `LibraryState`, `SavedSite`, `SourceCategory`, `Bookmark`, `NovelPosition`, `ChapterMerge` (Neko-style fill), `SourceError` |
| `SourceClient.swift` | `WebsiteHTTPClient` (see below) and `ImagePipeline` |
| `SiteAdapters.swift` | MangaDex (official API, picks one translation per chapter) and WeebCentral; `Discover` |
| `LinkedSource.swift` | Generic page and chapter detection for any site; `Webtoons` |
| `Search.swift` | `SearchSource` and `GlobalSearch`, including the `.syosetu` and `.kakuyomu` kinds |
| `Novels.swift` | `NovelText.extract` (reader mode), `Syosetu`, `Kakuyomu`, `Wuxiaworld`, `NovelSource` |
| `SourceManifest.swift` | Decodes `DefaultSources.json`; `parseList` for pasted lists |
| `Rar.swift` | `RarIndex`: reads RAR4/RAR5 tables of contents and extracts stored entries only |
| `LaunchQuotes.swift` + `CuratedQuotes.swift` | Launch card (see below) |
| `Books.swift`, `Archive.swift`, `FreeBooks.swift` | EPUB/MOBI/FB2/TXT/DOCX…, ZIP, Standard Ebooks / Gutenberg |

More detail on the bigger types:
- **`MangaSeries.Kind`** is `web`, `local`, `book` or `novel`. Helpers: `isNovel`, `isPlainBook`, `readsAsText`, `isOnline`.
- **`WebsiteHTTPClient`** is an ephemeral `URLSession` with cookies off. It sends an app user agent to `api.*` hosts, and a desktop user agent to webtoons, syosetu, kakuyomu and wuxiaworld.
- **`NovelText.extract`** looks for known containers first, then the densest text block. It strips CSS-hidden notices and drops navigation-only paragraphs.
- **Wuxiaworld** chapter lists are built from the first and latest chapter slugs in `__REACT_QUERY_STATE__`. Paid chapters come back as `locked`.
- **Launch card (`QuoteFeed`):**
  - Quotes come from the Yurippe and AnimeChan APIs. AniList checks each one: score of at least 77, and a kind and country allowed by `SpotlightPreference`.
  - Picks are AniList's top-rated series per kind.
  - When a series has both, `choose` prefers pictures over novels and an exact title over a spin-off.

### App

| File | What it holds |
|---|---|
| `LibraryModel.swift` | State, persistence, add/preview/commit links, updates, downloads, backup/restore, migrate, fill missing, favourites, bookmarks (`prepareToOpen`), `setLightNovel` |
| `NovelReader.swift` | Novel plumbing, `NovelTranslator`, `NovelReaderView`, `NovelBrowseSection` (see below) |
| `Sources.swift` | `Interests` (setup choices), source management on the model, `SiteSessions`, `SourcesPage`, `SourceEditSheet`, `SourceListImportSheet` (see below) |
| `BookReader.swift` | `BookTypesetter`, `BookPagerController`, `BookReaderView` (see below) |
| `ReaderView.swift` | Manga reader. Routes book chapters to `BookReaderView` and novel chapters to `NovelReaderView` |
| `ReaderContainerController.swift`, `PageCanvas.swift` | Paged and vertical image reader, page decode (border trim, enhance), panel finding |
| `BrowseView.swift` | Browse sections from sources, the in-app `MangaBrowserView` (Add, Read here, downloads into the library), `AddPreviewSheet` (manga or novel) |
| `SearchViews.swift` | `GlobalSearchModel.sources(saved:novels:)`, `GlobalSearchSheet(query:novels:nativeQuery:)`, `SimilarSheet`, `MigrateSheet` |
| `LibraryViews.swift` | Root tabs, library grid and tabs (`LibraryFilter`), `SeriesView`, all Settings pages, `BookmarksSheet`, categories |
| `Quotes.swift` | `SpotlightStore` (quote and pick queue), `SpotlightCard`, `HomeSetupSheet` (first-launch setup) |
| `Guide.swift` | Plain-language guide (Settings › Guide, the end of setup, and reader settings) |
| `LocalBooks.swift` | Files import: CBZ/ZIP, CBR (stored RAR via `importRar`), PDF, images, folders |
| `WebsiteView.swift` | `WebsiteBrowser` (WKWebView, default persistent data store, downloads) |
| `WebRendering.swift` | `PageRenderer`: off-screen WebKit render for script-built pages; shares the browser's data store |
| `OfflineStore.swift` | Downloads (novel chapters are stored as one JSON “page”) and custom covers |
| `AniList.swift`, `TranslateFeature.swift`, `Integrations.swift` | AniList tracking, manga OCR translation, Siri/Handoff/keyboard/controller |

More detail on the bigger App types:
- **`NovelReader.swift` plumbing:** `isNovel`, `novelInfo`, `addNovel`, `commitNovel`, `updateNovel`, `novelText`, and `downloadNovelChapter`.
- **`NovelTranslator`:** Apple Translation, paragraph by paragraph, cached under Caches/NovelTranslations.
- **`NovelReaderView`:**
  - It reuses the book typesetter and pager. The document is the chapter plus an ending section.
  - Landing on the ending page, or turning past either end through `pager.beyondEnd`, opens the next or previous chapter.
  - Re-layout keeps the reading position as a fraction of the chapter, so font changes and translation don't lose your place.
- **`Interests`:** setup choices stored in UserDefaults. Categories are a comma string (watch it with `@AppStorage(Interests.categoriesKey)`). Novels have their own key, `Features.novelsKey`.
- **Source management on the model:** `seedBundledSources` (runs every launch and respects `removedBundled`), update, reorder, remove, restore, `addSources`, and list subscriptions (re-read every launch).
- **`SiteSessions`:** sign-out deletes the site's WebKit cookies at once and clears its storage in the background. That background step can take minutes in WebKit, so never await it in UI. A keeper WKWebView keeps the cookie store responsive.
- **`BookPagerController`:**
  - It is guarded against replacing pages mid-turn (`animating` and `pending`).
  - Pages are set before the pager goes on screen. A page curl with zero pages throws.
- **`BookReaderView`:** keeps the largest safe area per screen shape (`steadySafe`) so a hiding status bar doesn't re-lay out mid-turn. That was a crash.

`Features` lives in `BookStore.swift`: `booksKey` and `novelsKey`. The app is a comics reader first, so books and novels are both off by default.

## Product rules (agreed with the owner, keep them)

- Picture content is the core. Light novels and books are setup or Settings options, off by default.
- **Sources:**
  - Bundled destinations live only in `Resources/DefaultSources.json`, which is decoded and tested by `SourceManifestTests`.
  - Do not add piracy sites to the manifest, to code, to “suggested” lists or to tests, and do not tune scrapers or probes for them. The owner has asked for several; this was declined, and the generic tools (any site in the browser, own lists and subscriptions, editable manifest) are the agreed answer. Existing entries (WeebCentral, Asura, MangaDot) were kept from the earlier catalog.
- **Sign-in:**
  - Never collect or transmit credentials.
  - Sign-in happens on the site inside the in-app browser.
  - “Read with my browser sign-in” makes the reader fetch that site through WebKit (`PageRenderer`), so cookies never leave WebKit.
  - `WebsiteHTTPClient` stays cookie-less on purpose, so browser challenge cookies are never exported.
- **Access controls:** don't bypass Cloudflare or bot checks, paywalls or DRM. Paid chapters show what the site shows, plus a “locked” note.
- **Writing style:** user-facing copy is plain, specific and short. Each setting explains itself, and the Guide covers buttons.
- **Commits:** end every message with the co-author lines used in this repo's history. Push to `main`.

## Verified live (latest probes)

| Source | Result |
|---|---|
| MangaDex | Pages show; licensed series are added from WeebCentral; fill-missing works (Jujutsu Kaisen, 272 chapters) |
| WeebCentral, WEBTOON, Asura, MangaDot | Pages show |
| Syosetu | Official API search and popular; table of contents is paged 100 per page; text in `js-novel-text` |
| Kakuyomu | Search page and work page from `__NEXT_DATA__` Apollo state; text in `widget-episodeBody` |
| Wuxiaworld | Martial World has 2,257 chapters; free chapters read; paid ones come back locked |
| AniList | Search, similar, quote rating and picks queries all accepted |
| Yurippe, AnimeChan | Quote feeds working |

These need a real browser, so they are browser destinations only:
- **J-Novel Club:** chapter text needs their login token.
- **Royal Road:** Cloudflare challenge from CI.
- **Digital Comic Museum:** Cloudflare challenge.

Comic Book Plus answers directly.

## Known gaps / next steps

1. **Untested on a real device:**
   - Apple Translation actually translating novels (only the plumbing is tested; the simulator can't download languages).
   - “Read with my browser sign-in” against a real account.
   - The browser's “Add book” and `target=_blank` downloads.
2. **Compressed CBR (RAR):** not supported; it shows a clear message. A RAR decompressor would be needed.
3. **Duo front screen:** the tab bar shows on the right side. Ask the owner whether that's the “weirdness” they meant (the Updates and History overlap is fixed).
4. **Kakuyomu tables of contents:** chapter groups are ordered by the work's `tableOfContents` or `tableOfContentsV2` when present, otherwise by first episode date. Confirm the field name on more works.
5. **Wuxiaworld chapter list:** built from slug numbering (`{prefix}{n}`). If a novel uses irregular slugs, fall back to `LinkedSource.chapterLinks`.
6. **Releases:** nothing is published to Releases yet. Push a `v*` tag to publish one.
7. **Not built:** MangaDex account sync. The planned personal-client form was dropped because it collects credentials.

## Where the latest IPA is

Actions › latest green “Build eclipsereader IPA” run › artifact `EclipseReader-unsigned-IPA` (zip containing the `.ipa`). Sideload it with AltStore, SideStore or Sideloadly.
