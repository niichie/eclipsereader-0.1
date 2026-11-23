# eclipsereader

## Status (v5)
Implemented in source (not yet compiled or device-tested):
- **Add manga from a link:** paste a series page and every chapter is added as one series, in reading order (works for manga and manhwa; includes Madara/WordPress chapter lists that load separately). Chapter links work too and open straight away.
- **Import from Files:** CBZ, ZIP (incl. ZIP64), PDF, images and folders, from iCloud Drive, USB drives and external SSDs. Copy into the app, or read in place from the original. A folder of chapter folders or CBZ volumes becomes one series. CBZ/PDF files can also be opened into the app from Files or the share sheet.
- **Library:** cover grid, series pages with full chapter lists, read/unread, continue, rename, remove, check for new chapters.
- **Reader:** one reader for every source; vertical scrolling turns on automatically for tall webtoon strips; next chapter follows the series list; white scan margins trimmed; facing pages centred as a spread.
- **Translate:** on-device text recognition (Apple Vision) plus Apple Translation (iOS 18+). Speech bubbles are detected and translated on the page; tap a card for the original; touch and hold to copy or correct; select an area manually; side panel mode. The artwork is never modified.

- **v5:** offline chapter downloads (with download-ahead and automatic downloads of new chapters), Updates and History tabs, automatic checks for new chapters, NEW badges, per-series reading style (manga / manhwa / comic, auto-detected), automatic and custom covers (any page or a photo), incognito mode, warm reading filter, backup and restore through Files / iCloud Drive, violet-and-amber eclipse theme, privacy manifest and hardened restore.

Known limits: sites that build pages entirely with scripts, or that block apps, need the in-app browser. Translation overlays are scanned from what is on screen: after zooming, tap rescan. Vertical Japanese recognition quality depends on Apple's Vision.

# eclipsereader

Eclipse is a Swift 6, SwiftUI and UIKit manga reader for iOS 17 or later. It discovers chapters and page URLs from readberserk.com and streams individual images. Each chapter has a separate entry and reading position. It does not create download folders or require chapter imports.

**Delivery status:** source implementation and build automation are included. No iOS compilation, simulator run, physical-device test, Signulous installation, or real IPA build has completed in this Windows session. There is deliberately no `.ipa` file in this source package. The workflow must succeed before its IPA can be described as built or installable. See [verification](Docs/VERIFICATION.md).

## Implemented experience

- OLED dark library, searchable chapter list, source order/newest-first sort, read/unread filtering and Continue Reading.
- Persistent chapter/page position, reading mode, fit, direction, transition and preferred double-tap zoom.
- Native horizontal reader with paper curl or slide, automatic aspect-fit and optional facing pages in sufficiently wide windows.
- Right-to-left spread placement: the earlier page is on the right. Artwork itself is never mirrored or split.
- Swipe left advances by default, as specified in the supplied project brief. Disable **Swipe left to advance** for the opposite book-turn gesture. Direction and swipe gesture are separate preferences.
- Continuous vertical mode uses reusable collection-view cells so scrolling a chapter does not retain every decoded image.
- Pinch zoom, double-tap zoom, panning, fit screen/width, reader-only dimming, tap to hide controls, page slider and end-of-chapter actions.
- On-demand loading, up to two encoded pages prefetched, cancellation, per-page retry and a temporary disk cache bounded to 120 MiB with a 24-hour lifetime.
- Explicit error states and an unmodified WKWebView Website Mode. That mode retains the site's own behavior and does not offer native page turning or native page progress.

These are implemented code paths, **not device-verified claims**. The optional wide-art detector uses metadata when available, otherwise image dimensions after a page loads. Unknown artwork can briefly be paired until its size is known. Wide pages remain whole.

## Build on Windows using GitHub Actions

You do not need Xcode, a Mac, an Apple developer certificate, or an Apple ID on this Windows machine to prepare this unsigned build. You need a GitHub account and access to a repository with macOS Actions runners. Runner availability and any usage charges depend on your GitHub plan. The workflow does not purchase runner time or configure billing.

1. Extract `EclipseReader-source.zip` and open the `EclipseReader` folder.
2. Sign into GitHub and create an **empty** repository. Choose private if you prefer. Do not initialize it with a README, license or `.gitignore` if using the commands below.
3. In Windows PowerShell, change to the extracted folder. Run the following, replacing the repository URL with your own. Git will handle authentication through your configured credential manager/browser; do not put tokens in these files.

```powershell
git init -b main
git add .
git commit -m "Add native Eclipse manga reader and unsigned iOS build"
git remote add origin https://github.com/YOUR-ACCOUNT/YOUR-REPOSITORY.git
git push -u origin main
```

If Git asks for a commit identity, configure your own name and email using `git config user.name` and `git config user.email`, then repeat the commit. If you use GitHub Desktop, create/add the extracted folder as a repository and publish it instead; include the `.github/workflows` directory.

4. Open the repository's **Actions** tab. Enable Actions if GitHub requires it. A push to `main` starts **Build unsigned iOS IPA** automatically.
5. To start a build manually, select **Build unsigned iOS IPA → Run workflow**. The source retains the existing bundle ID and sets the display name to **eclipsereader**.
6. Open the run. It selects Xcode 27.2 on `xcode-27`, resolves the dependency-free core package, runs core tests, builds XcodeGen from a pinned commit, generates the Xcode project, runs interface tests on iPhone, Duo and iPad simulators, and builds an unsigned arm64 **device** application.
7. The packaging step checks the iOS bundle platform and arm64 Mach-O metadata, packages `Payload/EclipseReader.app`, verifies ZIP integrity/resources/permissions, and writes a SHA-256 checksum. A simulator build will be rejected.
8. After the run succeeds, open its summary and download **EclipseReader-unsigned-IPA** from **Artifacts**. Extract the downloaded artifact ZIP. Inside it are `EclipseReader-unsigned.ipa` and its checksum. **Do not upload the outer artifact ZIP to Signulous.**

The diagnostic artifact contains logs and the simulator `.xcresult` bundle. Artifacts are retained for 14 days; rerun the workflow if an artifact expires. A failed run does not publish an IPA artifact.

Optional checksum verification in PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 .\EclipseReader-unsigned.ipa
Get-Content .\EclipseReader-unsigned.ipa.sha256
```

The hex hashes should match, ignoring letter case.

## Sign and install with Signulous

1. Finish the successful GitHub build above and put the actual `.ipa` somewhere accessible from your iPhone, such as Files/iCloud Drive. No manga files need to be transferred.
2. Open [Signulous](https://www.signulous.com/) on the iPhone you registered with the service and open its signing dashboard. Complete any existing device-registration requirements in your account.
3. Choose the dashboard option for uploading your own IPA. Labels can vary; select `EclipseReader-unsigned.ipa`, not the source ZIP or workflow artifact ZIP.
4. Keep the bundle identifier stable across updates. Ask Signulous to sign the uploaded application using your registered device/account, then use its installation action and follow the iOS prompts it supplies.
5. Open Eclipse, let the catalog load, select a chapter and read. If direct requests are refused, use **Open Website Mode**.

Signulous signs an existing IPA; it does not compile this Swift source. The unsigned artifact cannot be installed directly by iOS until a signing service signs it for an authorized device. No unknown signing profiles, certificates, special entitlements, JIT or jailbreak are part of this project. There is no guarantee of Signulous acceptance or device installation until a real build is signed and tested. This project avoids `xcodebuild -exportArchive`, which normally introduces provisioning/export requirements; it packages an unsigned device `.app` for subsequent re-signing.

## Project and tests

| Location | Purpose |
|---|---|
| `Sources/Core` | Models, source parser, network/redirect policy, source adapter, image pipeline, cache and atomic state persistence |
| `Sources/App` | SwiftUI library/settings/reader, native UIKit viewer and WKWebView fallback |
| `Tests/ReaderCoreTests` | Swift XCTest suite and observed HTML metadata fixtures; no manga image bytes |
| `Tests/AppUITests` | Launch, navigation, settings, rotation and relaunch smoke test |
| `project.json` | Reproducible XcodeGen project/scheme configuration |
| `.github/workflows/build-ios.yml` | macOS test/device build/IPA artifact workflow |
| `scripts` | Icon generator, portable checks, simulator selection, IPA packaging/verification |
| `Docs` | Source investigation, architecture, verification and troubleshooting |

The app itself uses only Apple frameworks. The build tool XcodeGen is fixed to version 2.44.1/commit `21ac9944b0ab546a07422dbed86f33dd2ebd76f8`; Xcode is explicitly selected rather than using the runner's changing default. GitHub images may still change or remove older Xcode versions, so the workflow records the toolchain and fails clearly if it is missing. This is a repeatable build recipe, not a claim of identical binary bytes across changing runner images.

On a compatible Mac, run:

```bash
swift package resolve
swift test --parallel
python3 scripts/validate_project.py
python3 scripts/test_packaging.py
xcodegen generate --spec project.json
```

The workflow shows the complete simulator/device commands. Local Windows checks can use Python 3 for `scripts/validate_project.py` and `scripts/test_packaging.py`; these do not compile Swift.

## Source compatibility and privacy

The adapter uses the observed chapter table and `img.pages__img` elements; it does not invent an API or generate manga URLs. The app makes ordinary HTTPS requests with its own user agent. It does not solve CAPTCHAs, export browser cookies, bypass anti-bot restrictions or mirror the site. Chapter HTML is fetched only for the chapter you open. Changing source markup/hosts causes a visible error rather than silent page loss.

Temporary image caching is separate from offline downloads: it is bounded, purgeable, and incomplete. A full-resolution encoded page is kept temporarily; decoding preserves its aspect ratio and caps the longest display dimension at 4096 pixels to limit memory. Ordinary 1200-pixel source pages retain their native resolution. Images above 40 megapixels or encoded files above 32 MiB are rejected. Vertical mode fits the entire width in each naturally proportioned page cell; fit-width vs fit-screen chiefly changes paged mode.

Progress and preferences remain in the app's on-device Application Support directory. Updating under the same signed bundle ID normally preserves them; deleting the app removes them. Website Mode uses WebKit's normal persistent website store, so the website may set its own cookies and load third-party resources. The app adds no analytics. No content-reuse license was established during investigation; robots.txt is not a copyright license. See [source investigation](Docs/SOURCE_INVESTIGATION.md).

Optional volume labels are omitted because no volume metadata was observed. There is no bundled chapter catalog posing as live data, no offline-download feature, and no cloud progress synchronization.

## References

- [GitHub macOS runners](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners)
- [Downloading workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)
- [macOS 15 runner toolchains](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-Readme.md)
- [XcodeGen project specifications](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
- [Apple native page-curl transition](https://developer.apple.com/documentation/uikit/uipageviewcontroller/transitionstyle-swift.enum/pagecurl)
- [Signulous custom IPA signing](https://www.signulous.com/)
