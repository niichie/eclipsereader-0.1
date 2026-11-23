# Troubleshooting

## No IPA is included with the source

Swift source is not an IPA. Run the macOS GitHub workflow; only its successful device build creates `EclipseReader-unsigned.ipa`. Windows cannot use Xcode/iOS SDKs locally. A simulator `.app` cannot be renamed or repackaged into a device app.

## The workflow does not appear

Ensure `.github/workflows/build-ios.yml` is committed at the repository root on `main`. Do not nest the extracted project inside another repository folder. Enable Actions if your repository requires it. A manual workflow appears only after its definition is on the default branch.

## No macOS runner, billing prompt or queued job

Check the account/organization Actions policy and runner quota. The workflow asks for `macos-15`; it does not buy runner time. Choose an available authorized macOS environment or adjust runner configuration yourself. Never use unsupported virtualized copies of macOS on Windows for this build.

## Xcode 16.4 or iOS 18.5 simulator missing

Check GitHub's current runner image manifest. The workflow deliberately fails instead of silently switching compilers. Update `DEVELOPER_DIR`, project Xcode version and simulator-selection script together to a compatible installed Xcode 16+ / Swift 6 environment, then rerun tests. The deployment target is iOS 17.

## Swift compile, core test or UI test fails

Download **EclipseReader-diagnostics** and inspect the first real compiler/test error in the relevant log. The source was not type-checked on Windows, so compilation errors may still exist. Fix the error and rerun; do not bypass failing checks to label an artifact working. The `.xcresult` can be opened with Xcode on a Mac. UI labels/layout can change across simulator OS versions; diagnose the actual hierarchy before changing a test.

## Bundle identifier/display name rejected

Use a valid reverse-DNS identifier containing letters, digits, dots and hyphens, with no spaces. Keep it stable for updates. The display name may include normal spaces; avoid control characters. Workflow inputs are passed as quoted environment values, not inserted directly into shell code.

## Artifact is missing or expired

The IPA upload step occurs only after all earlier checks pass. A diagnostics-only artifact means the build/test/package run failed. Inspect logs and fix that failure. Successful IPA artifacts expire after 14 days; rerun the workflow to obtain a new one. Download and extract the artifact ZIP before uploading the contained `.ipa` to Signulous.

## Signulous rejects the upload or iOS refuses installation

Verify you selected the real `EclipseReader-unsigned.ipa` artifact, not source or simulator files. Compare its SHA-256 checksum. Confirm device registration and signing eligibility in your Signulous account. Inspect the signing-service error and use its support if needed. Do not add arbitrary certificates/profiles or enable unrelated entitlements. This app needs no JIT, jailbreak or background capability.

## Catalog or chapter does not load

Use Retry once after checking connectivity. Visit the source in Safari. HTTP 401/403/429 may indicate a restriction or browser/session requirement; the app will not evade it. Use Website Mode or try again later. Website Mode can itself fail if the site does not support embedded browsers.

If Website Mode works but the native reader says the structure is unsupported, inspect the live source before editing `ReadBerserkParser`. Update observed selectors/host allowlists and add a new metadata fixture. Do not guess chapter URLs, scrape every image or forward challenge cookies into the reader.

## A page fails or stays on Retry

The source may have a broken URL or returned HTML instead of an image. Try Retry, then Website Mode/Safari for the same chapter. Check whether the site itself displays the page. Missing page URLs fail discovery rather than silently dropping pages. Decoding rejects oversized/malformed images and invalidates their cached data before another attempt.

## Wide artwork initially appears alongside another page

Some source tags lack dimensions. The reader detects aspect ratio after decoding and regroups known wide pages. Turn off landscape pairing or enable **Keep wide artwork on one page**. It never slices or mirrors the original image.

## Progress is lost

Deleting the app removes its local state. Re-signing under another bundle ID creates another app sandbox. Keep the same identifier for updates. Device storage failures produce a save warning. A corrupt state file gets an attempted backup in Application Support before a fresh state is used. No cloud backup/restore interface is implemented.

## Pages feel too small or large

Use Reader settings → Page size. Fit entire page avoids cropping; Fit width allows vertical panning of taller pages in paged mode. Pinch/double-tap to inspect details. Landscape pairing can be disabled. Vertical mode lays out natural-aspect pages at the available width. The website fallback has its own independent layout.
