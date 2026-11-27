<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="eclipsereader icon">
</p>

<h1 align="center">eclipsereader</h1>

<p align="center">
  A dark, manga-first reader for iPhone, iPad and iPhone Duo.<br>
  Right-to-left page turns for manga, seamless vertical strips for manhwa, everything kept on your device.
</p>

<p align="center">
  <a href="https://github.com/niichie/eclipsereader-0.1/actions/workflows/main.yml"><img src="https://github.com/niichie/eclipsereader-0.1/actions/workflows/main.yml/badge.svg" alt="Build"></a>
  <img src="https://img.shields.io/badge/iOS-17%2B-8a4dee" alt="iOS 17+">
  <img src="https://img.shields.io/badge/Swift-6-ffcc33" alt="Swift 6">
  <img src="https://img.shields.io/badge/devices-iPhone%20·%20iPad%20·%20Duo-222" alt="Devices">
</p>

---

## Features

### Library
- Mihon-style home that scales with the screen: a cover grid in three sizes, unread / **NEW** / downloaded badges and progress bars.
- Tabs with counts: All, **Favourites**, your own **categories**, Reading, New, Downloaded, Manga, Manhwa, Manhua, Webtoons, Comics, On device (plus Light novels and Books when you turn those on). The kinds you chose in the setup come first.
- **Select several series** to mark read, download, file into a category, hide or remove in one go.
- **One launch card that doubles as a recommendation:** a quote pulled live from two anime quote databases (Yurippe and AnimeChan) plus a hand-picked list, kept only when AniList readers rate the work 77% or higher and it's a kind you chose (manga, manhwa, manhua, light novels) from a country you chose. Top-rated picks of your kinds fill in where quotes are thin. It shows the cover, score and year; *Read* finds it on every site (light novels on the novel sites), and shuffle shows another. It never repeats a recent one or suggests something already in your library, and it shrinks on small screens.
- A **first-launch setup** asks what you're into (manga, manhwa, manhua, webtoons, comics; light novels and books as options), where from (Japan, Korea, China, Taiwan; raws too), and what the home shows. Change any of it in Settings › Library.
- **"Because you read"**: AniList recommendations based on the last series you read, matched to its kind (manga, manhwa, manhua, webtoons or comics), one per series, never something you already own. The shelf is saved, so it shows at once on launch.
- **Bookmarks** in every reader (Library ⋯ › Bookmarks) and **favourite series**.
- A plain-language **Guide** to every button and setting (Settings › Guide, the end of the setup, and the reader's settings).
- **Full cover control:** Photos, Files, an image link, any page of the series, or the automatic cover. Covers tint the series page.
- Hidden series behind Face ID, an app lock, reading stats with streaks, and Spotlight search for your library.

### Manga, manhwa, manhua, webtoons and comics
- **Manga:** right to left with paper-curl page turns. **Manhwa, manhua and webtoons:** one seamless vertical strip. **Comics:** left to right.
- Two-page spreads in landscape (and on the unfolded Duo), or **split spreads** into two pages in portrait. **Pairs** shifts the pairing by one page when double-page art lands split, remembered per series.
- **Page slider preview:** hold the slider and you see the page you'd land on with two pages either side, in reading order.
- A chapter is **marked read** as soon as its last page (or last pair) is on screen, or when you go on to the next chapter from its last pages.
- **Rotation lock** in the reader's bottom bar, for reading lying down.
- **Panels (guided view):** finds the panels on a page; edge taps zoom panel by panel (right to left for manga), then turn the page.
- Blank white or black scan borders are trimmed automatically.
- Keyboard and game controller page turns on iPad, auto-scroll for strips, haptics, plus artwork dimming and a warm night filter.
- On-device **translation of raw chapters** (Vision text recognition and Apple Translation): bubbles are remembered, and a pinned raw series translates every chapter automatically.
- **Scan enhancer** (on by default, on-device): grey paper turns white, faded ink turns black, JPEG noise is smoothed out and small scans are upscaled to your screen with clean lettering. Manga pages are kept in true greyscale; colour pages keep their colour. Hold two fingers on a page to compare with the original, and switch it off per series from the reader's ⋯ menu.
- Image quality matched to the screen, memory and Low Power Mode. Pages show instantly and the enhanced version swaps in place, with the next pages prepared ahead.

### Light novels and web novels (optional)
Off unless you turn it on in the setup or Settings › Library; eclipsereader is a comics reader first.
- Built in: **Syosetu** and **Kakuyomu** (where most Japanese light novels start; raw Japanese) and **Wuxiaworld** (official translations; free chapters read in full, paid ones say they're locked). Any other novel site works through reader-mode extraction: open a novel or one of its chapters in the browser and tap Add.
- Set like a printed book (the same typefaces, themes and page curl as books), and a chapter carries straight on into the next when you turn past its last page.
- **On-device translation** of raw chapters, paragraph by paragraph (Apple Translation), kept for next time; "always translate" per novel.
- Offline downloads, bookmarks, progress and updates, like any series. Light novel EPUBs can be shelved with novels instead of books.

### Books (optional)
Off unless you turn it on in the setup or Settings › Library (adding a book file turns it on). With books off, the Books tab and book search are hidden. There are no book quotes or book recommendations either way.
- Reads **EPUB, MOBI, AZW3, FB2, TXT, RTF, HTML, DOCX and ODT**, set like a printed book: left to right, page curl, two pages side by side in landscape, running heads and page numbers.
- Eight typefaces, size, spacing, margins, justification, and night, dusk, sepia or paper themes.
- Covers fetched automatically from Open Library and Google Books.
- Search and download public-domain books from **Standard Ebooks** and **Project Gutenberg** in the app (Gutenberg downloads fall back to its mirror when gutenberg.org is down).
- In the browser, a book's page (Standard Ebooks, Gutenberg, Wikisource or any page linking an EPUB) shows **Add book**; any EPUB, Kindle or FB2 download goes straight into the library.

### Browse and sources
- **Native connections:** MangaDex (official API), WeebCentral and WEBTOON.
- **One search across every site:** results fill in as each site answers, only sites that found something are shown, and the same series on several sites appears once (with "Open from" to pick the site). Sites that usually find things are searched first, and a site that hasn't answered your last 5 searches gets a one-tap **Turn off**. Your **recent searches** sit under the search field.
- **51 built-in sources** ready in Browse after install, grouped into manga, manhwa, manhua, webtoons, comics and novels. Among them: MangaDex, MANGA Plus, VIZ, K MANGA, Manga UP!, Comikey, WEBTOON, Tapas, Tappytoon, Lezhin, GlobalComix, Bilibili Manga, Comic Book Plus, Digital Comic Museum, Syosetu, Kakuyomu and J-Novel Club.
- **Sources** come from one editable file, `EclipseReader/Resources/DefaultSources.json` (format documented in the file): they appear in Browse after install, grouped by what they offer, and open in the in-app browser. Browse › Manage sources edits, hides, removes, reorders and favourites them, adds your own, or adds a whole list (pasted, from a file, or a link you **subscribe** to, re-read at every launch).
- **Sign in on any site** inside the in-app browser; sessions persist. A source set to "Read with my browser sign-in" loads its pages through that same session, so what your account can see opens in the reader too. Credentials and cookies never leave WebKit. Sign out of one site from its settings.
- Built-in browser for any other site, with ads, trackers and "get the app" banners blocked. The connected sources are checked against the live sites by the **Probe sources** workflow.
- The **Add** button only appears where a series can be read; elsewhere a guide explains why, with *Try anyway*.
- **Fill missing chapters** (from Neko): when a site lacks some chapters (licensed MangaDex series, say), the gaps are filled from the same series on another site. Adding a MangaDex series that only has a few chapters does this automatically. Only the missing numbers are added, they're refreshed on every update, and they give way once the main site posts them.
- **Similar series** (from Neko): AniList readers' recommendations for any series, with scores. Tap one to find it on every site.
- **Migrate** a series to another site, keeping your progress.

### Everything else
- **Downloads** for offline reading (Wi-Fi only if you like, delete after reading).
- **Updates** with new-chapter notifications and an app badge. **History** grouped by day.
- **AniList tracking:** link a series and finished chapters update your AniList list. Bring your own AniList client ID (Settings › Tracking).
- **Siri and Shortcuts** ("Continue reading", "Check for new chapters") and **Handoff** between your devices.
- **Files:** import CBZ, ZIP (including ZIP64), **CBR** (RAR 4 and 5 with pages stored uncompressed, the usual for comics; compressed RARs explain how to convert), PDF, images, folders and every book format above.
- Backup and restore (automatic backups too), incognito mode. No analytics or tracking.

## Install (sideload)

1. Download `EclipseReader-unsigned.ipa` from the newest **[release](https://github.com/niichie/eclipsereader-0.1/releases)**,
   or from the newest green **[Actions](https://github.com/niichie/eclipsereader-0.1/actions)** run (artifact **EclipseReader-unsigned-IPA**).
2. Install it with AltStore, SideStore, Sideloadly, Signulous or your usual signing tool.
3. Settings › About shows the version, build number and commit (for example `1.0.0 (140 · 5eddbf7)`), so you can tell which build you're running.

Pushing a tag like `v1.0` builds the IPA and publishes it as a release.

The app is built with the iOS 27 SDK, so the iPhone Duo runs it full-screen folded and unfolded. On iPhone (both Duo screens) the tabs sit in a bottom bar rather than the front screen's side rail, so pages use the full width.

## Build from source

Requirements: macOS with Xcode 27 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd EclipseReader
swift test                                # core parsing and archive tests
xcodegen generate --spec project.json     # creates EclipseReader.xcodeproj
open EclipseReader.xcodeproj
```

Every push builds an unsigned IPA in GitHub Actions, after the core tests pass. Two more checks run by hand from
**Actions**:

- **Probe sources** runs the app's own code against every listed site and book library, covers and page images included.
- **Device checks** runs the app on an iPhone simulator, opens real books and chapters in the real reader screens and
  waits for pages to appear.

## Project layout

| Path | What's there |
| --- | --- |
| `EclipseReader/Sources/Core` | Site reading (MangaDex / WeebCentral / WEBTOON adapters, generic page detection), search, book formats, panel detection, AniList, models, archives. No UI. |
| `EclipseReader/Sources/App` | SwiftUI app: library, series page, manga and book readers (UIKit page curl and vertical strips), browser, settings. |
| `EclipseReader/Tests` | Core unit tests, the live source probe, and on-device reader checks. |
| `EclipseReader/Docs` | Architecture notes and troubleshooting. |
| `.github/workflows/main.yml` | Tests, IPA build, and releases for version tags. |

## Privacy

Pages are fetched directly from the sites you add. Reading progress, downloads, recognized text and translations
stay on your device. There are no analytics or third-party SDKs. AniList is contacted only if you sign in, and your
AniList sign-in stays in the iOS Keychain.

## Disclaimer

eclipsereader is a personal project and doesn't include any manga. It isn't affiliated with MangaDex, WEBTOON,
WeebCentral, AniList, MyAnimeList, Open Library, Project Gutenberg or any other site it can open. Support the creators and official releases where you can.

Inspired by [Mihon](https://mihon.app/).
