# VoxHalo Native macOS Port Design

## Summary

Build a native macOS version of the Windows VoxHalo/TranslatePCCS real-time bilingual subtitle client. The macOS application will preserve the current product behavior while replacing WPF, Win32, Windows Forms, NAudio, and WASAPI with SwiftUI, AppKit, Core Audio, and Foundation networking.

The first release targets only the current development computer: Apple Silicon running macOS 26.0.1. It will be a native `arm64` application named **VoxHalo**, with bundle identifier `com.hellcatjack.voxhalo`, and will not ship a .NET runtime or third-party dependencies.

The Windows source at `https://github.com/hellcatjack/VoxHalo_win` remains an unmodified behavioral reference. The inspected reference head was commit `2f5627b14b4af5f476fef50f03f4cd269b031c09` on `master`.

## Confirmed Decisions

- Deliver full functional parity in the first usable macOS release.
- Include microphone, external/line input, and global system-output audio capture.
- Preserve Chinese-to-English and English-to-Chinese directions.
- Preserve the VoxBridge login, cookie, WebSocket, PCM, event, final-wait, and reconnection contracts.
- Preserve the transparent, always-on-top, click-through, multi-display subtitle overlay.
- Implement a native SwiftUI/AppKit application rather than an Avalonia or hybrid .NET application.
- Target only Apple Silicon and macOS 26.0 on this Mac.
- Store no authentication password in settings or Keychain.
- Build a locally signed `.app`; Intel support, App Store distribution, Developer ID notarization, and automatic updates are outside this release.

## Goals

- Produce a reliable native Mac application for live bilingual subtitles.
- Match the observable Windows client behavior, including subtitle reconciliation and privacy controls.
- Capture selectable hardware inputs and the Mac's outgoing system audio without a third-party virtual audio driver.
- Keep real-time audio callbacks independent from network and UI latency.
- Make platform-dependent components independently replaceable and testable.
- Produce a launchable `dist/VoxHalo.app` for this Mac.

## Non-Goals

- Do not modify, deploy, restart, or manage the VoxBridge backend.
- Do not host ASR or translation models locally.
- Do not preserve or execute the Windows WPF application inside the Mac app.
- Do not support Intel Macs or macOS versions older than 26.0 in this release.
- Do not add Keychain password persistence, transcript archives, cloud sync, accounts, auto-update, CI, or App Store packaging.
- Do not redesign the subtitle semantics or add new translation directions.
- Do not automatically migrate a Windows settings file from another computer. A manually copied compatible JSON file will still be sanitized when loaded.

## Architecture

The application uses Apple frameworks only: SwiftUI, AppKit, Foundation, Core Audio, AVFAudio, CoreGraphics, CoreText, and OSLog where appropriate.

```text
Selected audio source
  -> native capture implementation
  -> 16 kHz PCM16 mono frame accumulator
  -> bounded audio frame queue
  -> SessionCoordinator actor
  -> VoxBridgeClient actor
  -> VoxBridge backend
  -> typed protocol event parser
  -> SubtitleStateStore
  -> throttled main-actor display model
  -> operator window and AppKit overlay
```

The Xcode project is divided by responsibility:

```text
VoxHalo/
  App/
  Core/
  Networking/
  Audio/
  Session/
  Operator/
  Overlay/
  Persistence/
VoxHaloTests/
VoxHaloUITests/
docs/
scripts/
```

### App

`VoxHaloApp` owns the application lifecycle and dependency construction. An `NSApplicationDelegate` creates and retains the AppKit overlay controller, responds to display changes, and ensures capture, WebSocket, Core Audio tap, and aggregate-device resources are released during termination.

### Core

The Core module contains platform-neutral value types and subtitle behavior:

- `TranslationDirection` and the exact backend mappings `Chinese`/`zh2en` and `English`/`en2zh`;
- typed `VoxBridgeEvent` and stability metadata;
- `SubtitleRow` and `SubtitleDisplayModel`;
- a behavior-equivalent Swift port of `SubtitleStateStore`.

The state store preserves the current event semantics: backend sentence translations are authoritative; partial recognition changes only the reference stream; late and out-of-order translations are reconciled by sentence order; a corrected sentence keeps its old displayed translation until a replacement arrives; reset clears state; final/aggregate fields provide fallback material; whitespace is normalized; and target/reference history remains bounded to 24 segments.

No UI colors, AppKit types, audio types, or networking types enter this module.

### Concurrency

Networking and session coordination use Swift actors. UI state is isolated to `@MainActor`. Core Audio callbacks run on a dedicated serial audio queue and never wait for actors, WebSockets, disk I/O, or the main thread.

The audio queue converts and accumulates native samples, then places complete frames in a four-frame bounded ring buffer, representing at most 1.28 seconds of queued audio. A single session task drains frames in order. If the queue fills, it clears queued stale audio, marks the backend session faulted, reports `Audio pipeline overloaded`, and restarts the backend session before sending a later fresh frame. Memory use must not grow without bound.

## Audio

### Device Catalog

`CoreAudioDeviceCatalog` enumerates:

1. a synthetic `System Audio` source, selected by default;
2. every Core Audio device with an input stream, using its persistent device UID and user-visible name.

The catalog observes Core Audio hardware-change notifications and refreshes when devices are attached, removed, or renamed. A saved missing device falls back to System Audio before a session starts. If the active hardware device disappears, capture stops, the session returns to a stopped state, and the operator receives a device-disconnected message; the app never silently switches a running input.

### Hardware Input Capture

`HardwareInputCapture` binds an AUHAL audio unit to the selected Core Audio device ID resolved from its UID. It supports built-in microphones, USB interfaces, and line-input devices. The implementation requests microphone authorization before the first hardware-input session and includes `NSMicrophoneUsageDescription` plus the audio-input entitlement.

### System Audio Capture

`SystemAudioTapCapture` creates a private Core Audio global output tap with `CATapDescription`, attaches it to a private aggregate audio device, and captures the outgoing Mac mix through an AUHAL input path. It includes `NSAudioCaptureUsageDescription`, allowing macOS to request System Audio Recording permission on first use. Every tap and aggregate device is destroyed on Stop, startup rollback, or application exit.

### Conversion and Framing

Both capture paths use the same conversion boundary. Native interleaved or noninterleaved integer/float audio is downmixed and resampled to:

- 16,000 samples per second;
- signed 16-bit little-endian PCM;
- one channel;
- 320 ms frames;
- 10,240 bytes per complete frame.

`AVAudioConverter` performs production conversion. Pure conversion helpers accept synthetic buffers in tests. Partial trailing data is discarded on Stop rather than padded with artificial silence.

## VoxBridge Networking

### URL and Authentication

The default endpoint remains `wss://ushome.amycat.com:18024/ws`. Settings accept only absolute `ws://` or `wss://` URLs with a host.

When a nonblank password is present, the client derives `/login` on the same host and port, maps `wss` to `https` or `ws` to `http`, POSTs form fields `username` and `password`, and retains returned cookies for the WebSocket handshake. Blank passwords skip login. HTTP 401 maps to the concise authentication-failure message; other HTTP failures include only the status code and no response body or credential values.

The app supports user-selected insecure `ws://`/`http://` endpoints for Windows parity. Because the endpoint is user-configurable and cannot be enumerated by domain at build time, `Info.plist` sets `NSAppTransportSecurity.NSAllowsArbitraryLoads` to `true`. This is a deliberate compatibility exception, not a transport recommendation: the UI marks `ws://` endpoints as insecure and the public default remains TLS-protected.

### Messages

The client sends:

```json
{"type":"start","language":"Chinese","translation_direction":"zh2en"}
```

or:

```json
{"type":"start","language":"English","translation_direction":"en2zh"}
```

It sends audio as binary PCM messages and Stop as `{"type":"finish"}`. The networking layer also retains the existing `set_translation_direction` message capability even though the operator UI locks direction while running.

The parser recognizes `ready`, `started`, `partial`, `sentence_committed`, `sentence_updated`, `sentence_translation`, `sentence_reset`, `translation_direction`, `processing`, `final`, `error`, and `pong`. Unknown event types remain typed as unknown and are ignored unless explicitly treated as errors. The transport must deliver a fragmented server text message to the parser as one complete JSON document.

## Session Lifecycle

### Start

Start performs these steps in order:

1. validate the backend URL and selected audio source;
2. obtain the relevant macOS permission;
3. authenticate when a password is present;
4. connect the WebSocket;
5. reset the subtitle store for the selected direction;
6. send the direction-bearing `start` message;
7. start audio capture;
8. publish `Running`.

The client preserves actual Windows behavior and does not wait for `ready` or `started` before sending `start` or beginning capture.

### Recovery

A closed socket, receive error, backend error, failed audio send, or a gap of at least eight minutes between audio callbacks marks the backend session faulted. This gap is callback inactivity, not acoustic-silence detection. On the next available frame, a mutual-exclusion gate authenticates and reconnects once, sends a new `start`, then sends the fresh frame. Concurrent frames cannot create parallel reconnects.

### Stop

Stop is idempotent and mutually exclusive. It:

1. stops capture and removes audio callbacks;
2. sends `finish` when connected;
3. waits up to 120 seconds for `final` or `error` without blocking the main thread;
4. closes and cancels the session;
5. releases native audio resources;
6. publishes `Stopped`.

Subtitles remain visible after Stop. Starting the next session resets them.

## Operator Interface

The SwiftUI operator window uses native macOS controls and contains:

- backend URL;
- authentication username and secure password field;
- Chinese-to-English and English-to-Chinese direction selection;
- audio-source selection;
- display selection;
- Start, Stop, and current status;
- target area height, font size, top offset, and color;
- reference area height, font size, bottom offset, and color.

Backend, username, password, direction, and audio source lock while running. Display and subtitle-layout changes remain live. Start is disabled while running; Stop is disabled while stopped or while a prior Stop is completing.

The numeric defaults and normalization ranges match `AppSettings` in the Windows source:

- target area 264 points, range 120-640;
- target font 36 points, range 18-56;
- target top offset 0, range 0-900;
- reference area 96 points, range 48-360;
- reference font 24 points, range 16-42;
- reference bottom offset 0, range 0-900;
- target `#FFFFFF` and reference `#F4F4F4` defaults.

Both color pickers expose the existing six choices: White `#FFFFFF`, Soft White `#F4F4F4`, Warm Yellow `#FFD966`, Cyan `#8FE8FF`, Soft Green `#B7F7C4`, and Pink `#FFB3D1`.

## Subtitle Overlay

`SubtitleOverlayController` owns a borderless nonactivating `NSPanel`. The panel is transparent, nonopaque, excluded from normal window cycling, hidden from the Dock/window switcher, and does not accept key status. It uses `ignoresMouseEvents = true`, `NSWindow.Level.screenSaver`, and collection behaviors `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`, and `.ignoresCycle` so it remains above full-screen applications without taking focus.

The overlay fills the selected `NSScreen` and reacts to display configuration changes. Display persistence uses the UUID obtained from `CGDisplayCreateUUIDFromDisplayID`, not a temporary array index or raw `CGDirectDisplayID`. If the saved display disappears, the overlay moves to the main display.

The overlay reserves separate target and reference regions. Target translations form a continuous left-aligned stream in the upper region; the latest live source/reference content occupies the lower region. Both keep the bounded structured segments required by the state store and auto-scroll to the newest content, so older reference segments normally remain outside the visible viewport.

Text uses native glyph layout with a dark stroke and colored fill, retaining readability on bright and dark backgrounds. Target text is larger than reference text. Layout changes update immediately without activating the panel or intercepting pointer input.

The empty overlay appears when the application launches and remains present until the application exits.

## Settings and Diagnostics

### Settings

Settings are stored at:

```text
~/Library/Application Support/VoxHalo/settings.json
```

Writes use a temporary file plus atomic rename. Application Support and Logs directories use mode `0700`; the settings and diagnostic files use mode `0600`. Persisted fields include the safe backend URL, direction, audio device UID, display UUID, layout, colors, and authentication username.

Authentication passwords are never serialized and are never placed in Keychain. The settings store carries unknown JSON fields through later writes. Loading a manually copied legacy settings file removes any case-insensitive `AuthPassword` property while preserving unrelated known and unknown JSON fields. URL persistence strips userinfo, fragments, and query parameters named `token`, `access_token`, `refresh_token`, `id_token`, `session_token`, `api_key`, `apikey`, `password`, `passwd`, `secret`, `client_secret`, or `authorization`, compared case-insensitively after URL decoding. Invalid or non-WebSocket URLs fall back to the public default.

The following existing environment variables remain supported for command-line development launches:

- `VOXBRIDGE_AUTH_USERNAME`;
- `VOXBRIDGE_AUTH_PASSWORD`;
- `TRANSLATEPCCS_DIAGNOSTICS`;
- `TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS`.

Finder launches are not documented as inheriting shell environment variables; interactive password entry is the normal launch path.

### Diagnostics

Diagnostics remain disabled unless `TRANSLATEPCCS_DIAGNOSTICS=1`. When enabled, logs are stored with current-user-only permissions at:

```text
~/Library/Logs/VoxHalo/client.log
```

Passwords, cookies, authorization values, authentication usernames, audio device names, and device UIDs are always redacted. Recognition and translation bodies are redacted unless `TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS=1`. Backend host/port, event type, sequence information, text length, stability metadata, and nonsecret error categories may be logged.

## Error Handling

Startup is transactional. Invalid configuration, denied permission, authentication failure, WebSocket failure, or audio initialization failure stops and releases every service already started, restores the stopped UI state, and reports one concise error.

Permission failures offer an action to open the relevant macOS Privacy settings. Authentication failures never echo the username, password, cookies, response body, or URL credential material. A missing active hardware device stops the session instead of silently changing sources.

During a connection fault, the last stable subtitle remains visible. Malformed JSON produces a redacted parse diagnostic and does not crash the receive loop. Unknown non-error events are ignored. Backend `error` completes any pending final wait. Shutdown remains safe after failed or partial startup.

## Testing Strategy

The reference Windows suite contains 148 concrete test cases. The Mac suite will preserve portable behavioral coverage rather than mechanically translating Windows-only assertions.

### Unit Tests

- exact direction and JSON mappings;
- every parsed event field and unknown-event behavior;
- login URL derivation, form data, cookie propagation, binary audio, finish, and direction-change messages;
- fragmented WebSocket text delivery;
- subtitle commit, update, translation, reset, partial, processing, final, ordering, correction, continuous-stream, bounded-history, and allocation behavior;
- session startup order, final wait, concurrent Stop, reconnect gating, callback-gap recovery, and startup rollback;
- PCM downmix, resampling, clamping, endianness, frame sizing, bounded buffering, and overflow recovery;
- settings defaults, range normalization, URL sanitization, legacy-password removal, unknown-field preservation, atomic writes, and file permissions;
- diagnostic opt-in and every permanent/default redaction rule.

Tests use injected clocks, transport fakes, audio fakes, temporary directories, and permission providers. Network integration tests use an in-process local endpoint and synthetic credentials; they never infer real backend authentication behavior using guessed credentials.

### Native UI Tests

- panel transparency, nonactivation, click-through behavior, level, and Space behavior;
- selected display placement, negative coordinates, Retina point scaling, display removal fallback, and live display changes;
- target-above-reference layout, stroke readability, wrapping, auto-scroll, and live settings changes;
- main-actor update coalescing and UI responsiveness during event bursts.

### Manual Acceptance Tests

- grant, deny, and recover microphone and System Audio Recording permissions;
- capture built-in microphone, available USB/line input, and real system output;
- verify emitted PCM format and live latency;
- run both directions against `wss://ushome.amycat.com:18024/ws`;
- confirm live reference updates without rewriting stable target text;
- confirm reconnect behavior and 120-second Stop timeout handling;
- verify overlay readability, click-through behavior, multiple displays, Spaces, and full-screen applications;
- confirm settings and logs contain no password or permanently redacted identity/device values;
- relaunch the locally built `.app` and repeat a smoke session.

## Build and Packaging

The project targets Swift for `arm64` with macOS deployment target 26.0. Its property list includes `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, and the documented App Transport Security compatibility exception. App Sandbox is disabled for this local-only build. Hardened Runtime is enabled, and entitlements set `com.apple.security.device.audio-input` to `true`.

Build scripts produce:

```text
dist/VoxHalo.app
```

The application uses Xcode's **Sign to Run Locally** identity, the fixed bundle identifier, and the fixed output path. A rebuilt ad hoc-signed binary may require macOS permission approval again; final manual acceptance therefore runs against the unchanged final build. The build verifies the signature, entitlements, architecture, bundle metadata, and clean launch. Direct Developer ID distribution and notarization are intentionally deferred because this release is for this Mac only.

The current Mac does not have a usable Xcode developer toolchain: `xcode-select` cannot locate developer tools, `swift` cannot report a version, and the system `git` shim cannot run. A compatible Xcode installation must be installed, its license accepted, and its developer directory selected before compilation, testing, or a normal Git commit can be performed.

## Success Criteria

The port is complete when:

1. `VoxHalo.app` launches natively on this Apple Silicon Mac;
2. microphone, available external/line inputs, and global system audio all produce 16 kHz PCM16 mono frames;
3. both translation directions work with the existing VoxBridge endpoint;
4. authentication, cookies, event parsing, reconnect, final wait, and subtitle reconciliation match the Windows behavior;
5. the selected-display overlay is transparent, outlined, always on top, nonactivating, and click-through;
6. live layout settings and safe preferences persist across launches without storing a password;
7. diagnostics remain off and transcript-redacted by default, with permanent credential/operator/device redaction;
8. the complete native automated suite passes;
9. the manual acceptance matrix passes on this Mac;
10. the locally signed `dist/VoxHalo.app` relaunches successfully with the expected permissions and behavior.
