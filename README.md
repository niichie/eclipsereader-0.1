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
- Tabs with counts: All, your own **categories**, Reading, New, Downloaded, Manga, Manhwa, Manhua, Webtoons, Comics, On device (and Books, if you turn books on).
- **Select several series** to mark read, download, file into a category, hide or remove in one go.
- **One launch card that doubles as a recommendation:** a manga quote pulled live from two anime quote databases (Yurippe and AnimeChan) plus a hand-picked list, kept only when AniList readers rate the work 77% or higher. It shows the cover, score and year; *Read* finds it on every site, and shuffle shows another. It never repeats a recent quote or suggests something already in your library, and it shrinks on small screens.
- A **first-launch setup** lets you choose what the home shows (quote, Continue reading, Popular on MangaDex, Because you read…) and whether to read books too. Discover and Because you read are off by default. Change any of it in Settings › Library.
- **Full cover control:** Photos, Files, an image link, any page of the series, or the automatic cover. Covers tint the series page.
- Hidden series behind Face ID, an app lock, reading stats with streaks, and Spotlight search for your library.

### Manga, manhwa, manhua, webtoons and comics
- **Manga:** right to left with paper-curl page turns. **Manhwa, manhua and webtoons:** one seamless vertical strip. **Comics:** left to right.
- Two-page spreads in landscape, or **split spreads** into two pages in portrait.
- **Guided view:** finds the panels on a page and moves panel by panel (right to left for manga).
- Keyboard and game controller page turns on iPad, auto-scroll for strips, haptics, and a warm night filter.
- On-device **translation of raw chapters** (Vision text recognition and Apple Translation): bubbles are remembered, and a pinned raw series translates every chapter automatically.
- Optional enhancement for low-resolution scans; image quality matched to the screen, memory and Low Power Mode.

### Books (optional)
Off unless you turn it on in the setup or Settings › Library (adding a book file turns it on). With books off, the Books tab and book search are hidden. There are no book quotes or book recommendations either way.
- Reads **EPUB, MOBI, AZW3, FB2, TXT, RTF, HTML, DOCX and ODT**, set like a printed book: left to right, page curl, two pages side by side in landscape, running heads and page numbers.
- Eight typefaces, size, spacing, margins, justification, and night, dusk, sepia or paper themes.
- Covers fetched automatically from Open Library and Google Books.
- Search and download public-domain books from **Standard Ebooks** and **Project Gutenberg** in the app (Gutenberg downloads fall back to its mirror when gutenberg.org is down).
- In the browser, a book's page (Standard Ebooks, Gutenberg, Wikisource or any page linking an EPUB) shows **Add book**; any EPUB, Kindle or FB2 download goes straight into the library.

### Browse
- **Native connections:** MangaDex (official API), WeebCentral and WEBTOON. **Global search** across them, Asura Scans, MangaDot and your saved sites.
- More sites that add and read in the app: Asura Scans, MangaDot and Tapas. Every listed source is checked against the live site by the **Probe sources** workflow.
- Built-in browser for any other site, with ads, trackers and "get the app" banners blocked.
- The **Add** button only appears where a series can be read; elsewhere a guide explains why, with *Try anyway*.
- **Fill missing chapters** (from Neko): when a site lacks some chapters (licensed MangaDex series, say), the series page can fill the gaps from the same series on another site. Only the missing numbers are added, they're refreshed on every update, and they give way once the main site posts them.
- **Similar series** (from Neko): AniList readers' recommendations for any series, with scores. Tap one to find it on every site.
- **Migrate** a series to another site, keeping your progress.

### Everything else
- **Downloads** for offline reading (Wi-Fi only if you like, delete after reading).
- **Updates** with new-chapter notifications and an app badge. **History** grouped by day.
- **AniList tracking:** link a series and finished chapters update your AniList list. Bring your own AniList client ID (Settings › Tracking).
- **Siri and Shortcuts** ("Continue reading", "Check for new chapters") and **Handoff** between your devices.
- **Files:** import CBZ, ZIP (including ZIP64), PDF, images, folders and every book format above.
- Backup and restore (automatic backups too), incognito mode. No analytics or tracking.

## Install (sideload)

1. Download `EclipseReader-unsigned.ipa` from the newest **[release](https://github.com/niichie/eclipsereader-0.1/releases)**,
   or from the newest green **[Actions](https://github.com/niichie/eclipsereader-0.1/actions)** run (artifact **EclipseReader-unsigned-IPA**).
2. Install it with AltStore, SideStore, Sideloadly or your usual signing tool.

Pushing a tag like `v1.0` builds the IPA and publishes it as a release.

The app is built with the iOS 27 SDK, so the iPhone Duo runs it full-screen folded and unfolded.

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
