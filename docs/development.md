# Development and release

## Toolchain

- Xcode: `/Applications/Xcode.app`
- Swift language mode: Swift 6
- Swift package tools version: 6.2
- deployment target: macOS 26.0
- release architecture: arm64 only

All scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` where a build is performed. Accept the Xcode license before running tests or packaging.

## Source baseline

The unchanged Windows behavioral reference is `https://github.com/hellcatjack/VoxHalo_win.git`, commit `2f5627b14b4af5f476fef50f03f4cd269b031c09`. Native implementations should preserve portable observable behavior rather than Windows API structure.

## Common commands

```bash
swift build
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test list
```

Run focused tests with `swift test --filter TestClassName`.

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
Config                           bundle property list and entitlements
scripts                          build/run/verification helpers
```

## Test principles

- Use synthetic credentials only; never add live passwords to source, tests, shell commands, fixtures, snapshots, or documentation.
- Inject clocks, schedulers, transports, permission providers, catalogs, and Core Audio APIs.
- Test a failure before implementing its fix.
- Run focused tests, then the complete strict-concurrency/warnings-as-errors suite.
- Real microphone, system audio, permissions, backend, display/Space, and shutdown behavior remain manual release gates.

## Release bundle

`build-app.sh` performs a clean Release arm64 product build, recreates `dist/VoxHalo.app`, installs only the mode-0755 executable and mode-0644 Info.plist, ad hoc signs with Hardened Runtime and the audio-input entitlement, then calls the verifier.

The verifier checks plist syntax/identity/minimum OS, exact arm64 architecture, strict signature validity, runtime flag, audio-input entitlement, absent sandbox entitlement, and absence of source, private runtime data, or Windows artifacts.

Do not rebuild between permission approval and the final manual checklist. Record the app commit and signature hash, then test the unchanged bundle. Rebuilding changes the local signature and may reset macOS privacy approval.

## Release scope

This build is local-only. Do not describe it as notarized or distributable. A future external release needs a Developer ID identity, hardened signing review, notarization/stapling, supported deployment range, update strategy, and a separate privacy/security review.
