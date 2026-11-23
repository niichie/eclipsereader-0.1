# Verification status

Recorded 20 November 2026. Do not interpret source generation or syntax parsing as a successful iOS build.

## Completed in the Windows session

- Real browser inspection of the home page/chapter 384 and its actual page image elements.
- Responsive website check at 390 × 844; temporary viewport override restored afterward.
- Ordinary HTTP 200 responses for the home page, chapter 384 and robots.txt, using the proposed app user agent.
- Ordinary HEAD request to an observed CDN image: HTTP 200, JPEG response, 264,126 bytes declared. No image downloaded into the deliverable.
- Portable HTML audit of the actual saved responses: 405 chapter rows and 25 ordered chapter-384 page URLs, with the observed eager/lazy attributes. This is **not execution of the Swift adapter**.
- The adapter's regex patterns were also cross-checked against the complete responses using Python's regex engine, yielding the same counts/order. Native Foundation/ICU execution remains for CI.
- JSON and plist parsing, project source paths, unsigned settings, RGB icon dimensions/CRC checks and cross-engine regex syntax checks.
- Tree-sitter Swift grammar parse of all 14 Swift files, with no ERROR or missing syntax nodes. This is **not Swift type checking**.
- Workflow YAML parsed successfully on Windows.
- Seven Python packaging-validator tests passed. These use small synthetic Mach-O metadata buffers to test rejection/acceptance rules; they are not executable applications and no synthetic IPA is distributed.

## Authored but not executed here

The Swift XCTest suite covers observed full/excerpt HTML fixtures, chronology including prologues/decimals, URL validation, unsupported/missing page markup, RTL/landscape order, wide artwork grouping, portrait grouping, both swipe conventions and boundaries, state round trips/corruption, status failures, cache expiry/eviction/limits/clear, prefetch bounds, cancellation and network-failure propagation.

The simulator UI test covers library/settings navigation, rotation and relaunch. Its `--ui-testing` flag only disables automatic refresh; it does not substitute fake chapters or alter Release behavior.

These tests run in the GitHub macOS workflow. Windows has no Swift compiler, iOS SDK, Xcode, or configured macOS runner in this session. GitHub repository/build access was requested but no repository/run was supplied. Therefore:

| Verification | Status |
|---|---|
| Swift type checking / app compilation | Not run |
| Swift core XCTest execution | Not run |
| Native simulator UI tests | Not run |
| Physical iPhone reader behavior | Not run |
| On-device URLSession image streaming | Not run |
| WKWebView compatibility | Not run |
| Real arm64 device application / IPA packaging | Not run |
| Signing / Signulous acceptance / installation | Not run |

No working IPA, installation success, or production readiness is claimed.

## Device acceptance checklist after a successful CI build

1. Install the actual signed IPA using Signulous. Launch on the intended iPhone and refresh the catalog. Check that A0 is first in oldest-first order and verify the site's latest chapter against the live website.
2. Open an early and a recent chapter. Confirm image ordering, page counts and legibility; test Wi-Fi and mobile data. No full-chapter download should be necessary.
3. In default RTL mode, verify left swipe advances and right swipe returns. Toggle the alternate swipe convention and verify both. Check that images themselves are not mirrored.
4. Rotate with a portrait page, an odd final page and genuine wide artwork. Earlier pages must appear on the right; wide artwork must remain whole. Try disabling spread detection.
5. Test pinch/double-tap zoom and panning in paged and vertical modes. Verify fit screen/width and recovery after rotation. Confirm a zoomed pan does not unintentionally turn a page.
6. Test curl and slide, interactive/cancelled turns, Reduce Motion, hiding controls, Dynamic Island/notch safe areas and both landscape orientations.
7. Change reading settings, background/terminate/relaunch and Continue Reading. Verify chapter/page, direction, fit, mode and double-tap preference survive. Use the end action to mark read and open the next chapter.
8. Disable networking while opening an uncached page. Verify a visible error/retry, recovery after reconnecting, and no endless reload loop. Test a removed chapter and HTTP failure if a controlled development stub is available.
9. Read several long chapters while checking memory with Xcode Instruments when available. Ensure decoded images are released, old cache files expire/evict, and clearing temporary images works. Do not use this check to bulk-download the website.
10. Test Website Mode on the device. Verify the site's original chapter navigation and reload work, external links behave appropriately, and no native-RTL/progress capability is implied.
11. Update the signed application with the same bundle ID and check progress preservation. Test app exit/restoration and interruption during a slow image load.

Save actual run links, logs and any discovered defects alongside this document when the macOS/device checks are performed.
