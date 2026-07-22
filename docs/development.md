# Development and release

## Toolchain

- Xcode: `/Applications/Xcode.app`
- Swift language mode: Swift 6
- Swift package tools version: 6.2
- deployment target: macOS 26.0
- release architecture: arm64 only

All scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` where a build is performed. Accept the Xcode license before running tests or packaging.

## Source baseline

The Windows behavioral reference is `https://github.com/hellcatjack/VoxHalo_win.git`, currently ported through commit `0867afe48e2196e84512c842aacb6117a1f8799e`. The original native-port baseline was `2f5627b14b4af5f476fef50f03f4cd269b031c09`; commits through `0867afe` add the complete ASR hotword-context feature and hardening. Native implementations preserve portable observable behavior rather than Windows API structure.

## Common commands

```bash
swift build
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test list
```

Run focused tests with `swift test --filter TestClassName`.

An opted-in live run can be replayed through the exact production state store
and AppKit renderer without storing any transcript in the repository. Record the
first diagnostic line before Start and the final line after Stop, then run:

```bash
VOXHALO_LIVE_DIAGNOSTIC_LOG="$HOME/Library/Logs/VoxHalo/client.log" \
VOXHALO_LIVE_DIAGNOSTIC_FIRST_LINE=<first-line> \
VOXHALO_LIVE_DIAGNOSTIC_LAST_LINE=<last-line> \
VOXHALO_LIVE_REPLAY_SNAPSHOT=/tmp/voxhalo-live-replay.png \
VOXHALO_LIVE_FOLLOWER_SNAPSHOT=/tmp/voxhalo-live-follower.png \
swift test --filter LiveDiagnosticReplayTests
```

The gated test reconstructs production-shaped subtitle events, verifies that
every matched explicit revision refreshes the active translation immediately,
reports numeric-only backend latency and reflection metrics, verifies that
rendered history never changes after it leaves the live tail, simulates a reader
scrolling back, asserts that later events preserve that position, and drives a
second view that must remain exactly at the newest edge through every append and
active-tail correction. It requires at least 95% bidirectional word-sequence
coverage against a completed backend `final` and can write separate pixel
snapshots for the reader and follower views. It skips in ordinary test runs.

Render and pixel-check white, yellow, and cyan subtitles against video panels
of the exact same colors:

```bash
VOXHALO_CONTRAST_SNAPSHOT=/tmp/voxhalo-contrast.png \
swift test --filter SubtitleOverlayViewTests.testSameColorBackgroundsRetainDarkSubtitleEdges
```

The test requires dark separating edge pixels in every panel, renders a dimmer
stable sentence beside a brighter active sentence, and optionally writes the
complete bilingual comparison board for visual inspection.

Build and verify the release application:

```bash
scripts/build-app.sh
scripts/verify-app.sh dist/VoxHalo.app
```

Run the opt-in packaging gate:

```bash
VOXHALO_RUN_PACKAGING_TESTS=1 swift test --filter ProjectPackagingTests
```

Open a freshly built instance:

```bash
scripts/run-app.sh
```

## Package layout

```text
Sources/VoxHaloKit/Core          protocol-neutral subtitle behavior
Sources/VoxHaloKit/Networking    authentication, HTTP, WebSocket, wire data
Sources/VoxHaloKit/Audio         catalog, capture, conversion, bounded transfer
Sources/VoxHaloKit/Session       actor lifecycle, reconnect, final wait
Sources/VoxHaloKit/Display       persistent NSScreen catalog
Sources/VoxHaloKit/Overlay       AppKit panel and CoreText rendering
Sources/VoxHaloKit/Operator      main-actor model and SwiftUI console
Sources/VoxHaloKit/Persistence   safe settings and diagnostics
Sources/VoxHaloKit/App           live dependency environment
Sources/VoxHaloApp               SwiftUI entry point and AppKit delegate
Sources/VoxHaloRealtimeAudio     native real-time ring boundary
Tests/VoxHaloKitTests            deterministic unit/native integration tests
Config                           bundle metadata, entitlements, PCCS icon source
scripts                          build/run/verification helpers
```

## Test principles

- Use synthetic credentials only; never add live passwords to source, tests, shell commands, fixtures, snapshots, or documentation.
- Use synthetic hotwords in tests/docs and verify diagnostics receive only hotword metadata, never configured term arrays or backend error text.
- Inject clocks, schedulers, transports, permission providers, catalogs, and Core Audio APIs.
- Test a failure before implementing its fix.
- Run focused tests, then the complete strict-concurrency/warnings-as-errors suite.
- Real microphone, permissions, display/Space, and shutdown behavior remain manual release gates. Real system audio and backend behavior can additionally feed the opt-in live diagnostic replay above.

## Release bundle

`build-app.sh` performs a clean Release arm64 product build, recreates `dist/VoxHalo.app`, installs the mode-0755 executable and mode-0644 Info.plist, generates every 16–1024-pixel macOS icon representation from the vendored square PCCS source, compiles `VoxHalo.icns`, ad hoc signs with Hardened Runtime, the audio-input entitlement, and a bundle-identifier designated requirement, then calls the verifier.

The verifier checks plist syntax/identity/minimum OS/icon name, the valid ICNS 1024-pixel representation, exact arm64 architecture, strict signature validity, runtime flag, stable non-CDHash designated requirement, audio-input entitlement, absent sandbox entitlement, and absence of source, private runtime data, or Windows artifacts.

`Config/PCCSAppIconSource.png` is the exact 512 × 512 square brand image published by the official PCC South site at `https://pcc-south.org/assets/wechat-share-logo.png` (SHA-256 `952e3bf721b3746565b2d01b4a47a0788dfb3a5076fae1663f63285d017fc34d`). The asset is vendored, so ordinary builds do not contact the site. `sips` performs deterministic size generation and `iconutil` produces the signed bundle resource.

Do not rebuild between permission approval and the final manual checklist. Record the app commit and signature hash, then test the unchanged bundle. The explicit designated requirement is stable, but an ad hoc signature is not a Developer ID identity; macOS can still retain legacy CDHash entries for Keychain and privacy authorization. Rebuilding may therefore require another local confirmation.

## Release scope

This build is local-only. Do not describe it as notarized or distributable. A future external release needs a Developer ID identity, hardened signing review, notarization/stapling, supported deployment range, update strategy, and a separate privacy/security review.
