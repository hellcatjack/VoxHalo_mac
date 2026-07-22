# VoxHalo for macOS

VoxHalo is a native Apple Silicon application for real-time Chinese ↔ English subtitles. It captures either the Mac's playing system audio or a selected microphone/input device, streams bounded PCM audio to VoxBridge, and renders a transparent click-through subtitle overlay on the chosen display.

This repository is the macOS port of the Windows behavioral reference at `hellcatjack/VoxHalo_win`. The port was checked against Windows commit `2f5627b14b4af5f476fef50f03f4cd269b031c09` and preserves its login, WebSocket, subtitle reconciliation, reconnect, final-wait, settings, and privacy behavior with native macOS replacements.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later
- Xcode 26 with its license accepted
- VoxBridge access for live translation

The project uses Swift 6 and Apple frameworks only. It has no third-party package or .NET runtime dependency.

## Build and run

```bash
scripts/build-app.sh
open -n dist/VoxHalo.app
```

Or build and open in one command:

```bash
scripts/run-app.sh
```

The fixed output is `dist/VoxHalo.app`, built as Release arm64, locally signed with Hardened Runtime, and verified before the build script returns.

## Tests

```bash
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
VOXHALO_RUN_PACKAGING_TESTS=1 swift test --filter ProjectPackagingTests
```

The suite covers the wire protocol, authentication cookies, subtitle state, reconnect/final-wait behavior, Core Audio setup and rollback, PCM conversion/framing, bounded queues, persistence/privacy, multi-display overlay behavior, operator UI, shutdown, and release packaging.

## First use

1. Launch `dist/VoxHalo.app`.
2. Keep the default TLS endpoint or enter another absolute `ws://`/`wss://` endpoint.
3. Enter the login username and password. The password remains in memory only.
4. Choose a direction, audio source, and display.
5. Click **Start** and approve the relevant macOS permission when prompted.
6. Click **Stop** before changing the endpoint, direction, or audio source.

The overlay is transparent, always on top, nonactivating, click-through, and visible across Spaces/full-screen applications. Display and layout controls remain live while a session is running.

## Private local data

- Settings: `~/Library/Application Support/VoxHalo/settings.json`
- Opt-in diagnostics: `~/Library/Logs/VoxHalo/client.log`

Passwords are not written to settings, diagnostics, the bundle, or Keychain. Diagnostics are disabled by default. See [configuration](docs/configuration.md), [security and privacy](docs/security-and-privacy.md), and the [user guide](docs/user-guide.md) for details.

## Documentation

- [User guide](docs/user-guide.md)
- [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Development and release](docs/development.md)
- [Security and privacy](docs/security-and-privacy.md)
- [Manual acceptance checklist](docs/manual-test-checklist.md)

This release is intended for this Mac. Developer ID distribution, notarization, Intel support, App Store sandboxing, automatic updates, and password persistence are intentionally outside its scope.
