# VoxHalo for macOS

VoxHalo is a native Apple Silicon application for real-time Chinese ↔ English subtitles. It captures either the Mac's playing system audio or a selected microphone/input device, streams bounded PCM audio to VoxBridge, and renders a transparent click-through subtitle overlay on the chosen display.

This repository is the macOS port of the Windows behavioral reference at `hellcatjack/VoxHalo_win`. The port is current through Windows commit `0867afe48e2196e84512c842aacb6117a1f8799e` and preserves its login, ASR hotword context, WebSocket, subtitle reconciliation, reconnect, final-wait, settings, and privacy behavior with native macOS replacements.

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

The suite covers hotword parsing and privacy, the wire protocol, authentication cookies, subtitle state, reconnect/final-wait behavior, Core Audio setup and rollback, PCM conversion/framing, bounded queues, persistence/privacy, multi-display overlay behavior, operator UI, shutdown, and release packaging.

## First use

1. Launch `dist/VoxHalo.app`.
2. Keep the default TLS endpoint or enter another absolute `ws://`/`wss://` endpoint.
3. Enter the login username and password. Enable **Save in Keychain** to reuse it securely after relaunch.
4. Choose a direction and optionally enter rare names or professional terms in **Hotwords**.
5. Choose an audio source and display.
6. Click **Start** and approve the relevant macOS permission when prompted.
7. Click **Stop** before changing the endpoint, direction, hotwords, or audio source.

The overlay is transparent, always on top, nonactivating, click-through, and visible across Spaces/full-screen applications. Display and layout controls remain live while a session is running.

## Private local data

- Settings: `~/Library/Application Support/VoxHalo/settings.json`
- Opt-in diagnostics: `~/Library/Logs/VoxHalo/client.log`

Passwords are never written to settings, diagnostics, or the bundle. When explicitly enabled, the endpoint/username/password tuple is stored only as a generic password in this Mac's Keychain after a successful Start. Hotword input is automatically stored as plaintext in the private settings file and sent to the selected backend, so inspect it before sharing that file. Hotword arrays and backend error text are never written as diagnostic fields. Diagnostics are disabled by default. See [configuration](docs/configuration.md), [security and privacy](docs/security-and-privacy.md), and the [user guide](docs/user-guide.md) for details.

## Documentation

- [User guide](docs/user-guide.md)
- [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Development and release](docs/development.md)
- [Security and privacy](docs/security-and-privacy.md)
- [Manual acceptance checklist](docs/manual-test-checklist.md)

This release is intended for this Mac. Developer ID distribution, notarization, Intel support, App Store sandboxing, and automatic updates are outside its scope.
