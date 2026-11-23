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
- Cover grid in three sizes, with titles on the covers, unread / **NEW** / downloaded badges and a progress bar.
- Category tabs with counts: All, Reading, New, Downloaded, Manga, Manhwa, Comics, On device.
- Sort by recently read, title or recently added. A slim *Continue reading* bar picks up where you stopped.
- **Full cover control:** choose from Photos, Files, an image link or any page, or go back to the automatic cover.

### Reader
- **Manga by default:** right to left, paper-curl page turns, drag right or tap the left edge to go forward.
- **Manhwa and webtoons** are detected from the site and the page shapes, then scroll as one seamless strip.
- Two-page spreads in landscape (wide artwork stays on one page). Margin trimming keeps a little paper around the art.
- Floating controls: chapter skip, a page slider that follows the reading direction, and quick toggles for mode, crop, gap and warm night filter.
- Long-press a page to share it, save it to Photos or make it the cover.
- On-device **tap-to-translate** (Vision text recognition and Apple Translation).
- Image quality matched to the device's screen, memory and Low Power Mode.

### Browse
- **Native connections:** MangaDex (search and popular titles through its official API), WeebCentral and WEBTOON.
- Built-in browser for any other site, including Asura Scans, MangaDot, MangaBall, Comix and official publishers. Ads, trackers and "get the app" banners are blocked.
- The **Add** button knows what's on screen. It shows the chapter count on a series page, a preview before adding, and refuses listing and home pages.

### Everything else
- **Downloads** for offline reading, optionally downloading ahead and new chapters automatically.
- **Updates:** new chapters across the library. **History:** grouped by day, one entry per series.
- **Files:** import CBZ, ZIP (including ZIP64), PDF, images or folders, copied or read in place from an external drive.
- Backup and restore through iCloud Drive or Files. Incognito mode. No accounts, analytics or tracking.

## Install (sideload)

1. Open **[Actions](https://github.com/niichie/eclipsereader-0.1/actions)** and pick the newest green **Build eclipsereader IPA** run.
2. Download the **EclipseReader-unsigned-IPA** artifact and unzip it.
3. Install `EclipseReader-unsigned.ipa` with AltStore, SideStore, Sideloadly or your usual signing tool.

The app is built with the iOS 27 SDK, so the iPhone Duo runs it full-screen folded and unfolded.

## Build from source

Requirements: macOS with Xcode 27 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd EclipseReader
swift test                                # core parsing and archive tests
xcodegen generate --spec project.json     # creates EclipseReader.xcodeproj
open EclipseReader.xcodeproj
```

Every push to `main` builds an unsigned IPA in GitHub Actions. To photograph every screen on iPhone, iPad and the Duo
simulators, run the workflow by hand (**Actions › Build eclipsereader IPA › Run workflow**). The pictures come back as the
**screenshots** artifact.

## Project layout

| Path | What's there |
| --- | --- |
| `EclipseReader/Sources/Core` | Site reading (page and chapter detection, MangaDex / WeebCentral / WEBTOON adapters), models, archives. No UI. |
| `EclipseReader/Sources/App` | SwiftUI app: library, series page, reader (UIKit page curl and vertical strips), browser, settings. |
| `EclipseReader/Tests` | Core unit tests and UI tests, including the screenshot tour. |
| `EclipseReader/Docs` | Architecture notes and troubleshooting. |
| `.github/workflows/main.yml` | IPA build and the optional screenshot job. |

## Privacy

Pages are fetched directly from the sites you add. Reading progress, downloads, recognized text and translations
stay on your device. There are no accounts, analytics or third-party SDKs.

## Disclaimer

eclipsereader is a personal project and doesn't include any manga. It isn't affiliated with MangaDex, WEBTOON,
WeebCentral or any other site it can open. Support the creators and official releases where you can.

Inspired by [Mihon](https://mihon.app/).
