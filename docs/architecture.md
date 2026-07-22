# Architecture

## Baseline and boundaries

VoxHalo is a native Swift/AppKit/SwiftUI port of the Windows source through commit `0867afe48e2196e84512c842aacb6117a1f8799e`. Portable behavior is preserved; platform APIs are replaced at explicit boundaries.

| Windows responsibility | macOS implementation |
|---|---|
| WPF operator and subtitle windows | SwiftUI operator view plus AppKit `NSPanel` overlay |
| Win32 monitor enumeration | `NSScreen` plus `CGDisplayCreateUUIDFromDisplayID` |
| WASAPI/NAudio capture | Core Audio process tap and AUHAL input |
| .NET WebSocket/HTTP | ephemeral `URLSession` HTTP and WebSocket transports |
| JSON settings under AppData | atomic private JSON under Application Support |
| Dispatcher throttling | main-actor 80 ms coalescing pump |

The executable depends only on `VoxHaloKit` and the small C++ real-time ring target. There are no third-party packages.

## Data flow

```text
selected system/hardware source
  → native Core Audio capture
  → AVAudioConverter (16 kHz, signed PCM16 LE, mono)
  → exact 10,240-byte / 320 ms accumulator
  → four-frame bounded queue
  → SubtitleSessionCoordinator actor
  → VoxBridgeClient actor
  → authenticated WebSocket
  → typed VoxBridge events
  → SubtitleStateStore
  → 80 ms main-actor update pump
  → click-through AppKit overlay

operator Hotwords text
  → AsrContextTermsParser validation
  → immutable session term snapshot
  → start.asr_context_terms on initial connect and reconnect
  → started acknowledgement metadata/status
```

## Modules

### Core

`TranslationDirection`, protocol events, subtitle rows, display models, and `SubtitleStateStore` contain no UI, networking, or audio APIs. The store preserves authoritative translations, partial reference updates, late/out-of-order reconciliation, reset/final fallbacks, and continuous target text. The target keeps 96 whole sentence segments while the lower reference remains bounded to 24.

Rendered translations use a client-side stabilization layer without changing the backend protocol. Canonical rows continue to accept every backend revision, while visible history becomes immutable as soon as a newer source sentence arrives. Backend stable metadata and punctuation-complete prefixes freeze rendered text sooner. While a sentence is still the active tail, every explicit `sentence_updated` authorizes its matching translation to refresh immediately, including shorter or structurally different corrections; sequence-aware pending revisions prevent an older response from hiding a newer one. Ordinary translation-only rewrites and shorter rollbacks remain blocked, while append-only growth remains visible. When the next source sentence arrives—or the session reaches `final`—the latest active translation is finalized and becomes immutable. This keeps the current sentence live without allowing older sentences or a reader's scroll anchor to churn. Partial aggregate fallback text is append-only after first display. The rendered paragraph is bounded only at whole-sentence boundaries; it no longer deletes one leading character for every character appended after 480 UTF-16 units. Final redecode/reconciliation resets retain the old display while canonical rows rebuild, then replace it atomically on `final`.

`LiveDiagnosticReplayTests` can consume an explicitly opted-in diagnostic slice after a real run. It reconstructs production-shaped events, applies the same state store and AppKit overlay, requires every matched active source revision to appear in the returned display model immediately, and reports backend revision-to-translation latency. Two independent views exercise both reading intents after every event: one remains pinned above the newest line while the other must remain exactly at the newest edge through appends and structural active-tail corrections. Whenever both history and an active tail exist, the replay also requires the newest translation to have a distinct fill color. The replay checks every later scroll origin and frozen prefix and can render a pixel snapshot of either view. For a completed slice it compares the rendered target against the authoritative final with a longest-common-subsequence metric and requires at least 95% coverage in both directions. No live transcript fixture is committed.

### Networking

`AsrContextTermsParser` splits operator hotword input, preserves first spelling/order while deduplicating case-insensitively, validates the backend's 24-term/160-Unicode-scalar limits, and rejects sentence punctuation without silently truncating. `VoxBridgeAuthenticator` derives `/login` on the endpoint authority, changes `wss` to `https` or `ws` to `http`, submits form-encoded credentials, and forwards response cookies into the WebSocket handshake. The WebSocket client serializes start/audio/direction/finish sends and parses complete text messages. Errors exposed upward contain categories or HTTP status only.

### Audio

`CoreAudioDeviceCatalog` exposes a synthetic System Audio source plus live hardware input devices identified by persistent Core Audio UID. `SystemAudioTapCapture` creates a private global process tap and aggregate device, then reads that device through the direct `AudioDeviceIOProc` path used by Apple's tap sample. `HardwareInputCapture` keeps AUHAL for the selected physical input device. Both feed the same converter and accumulator.

The real-time callback never performs disk, network, actor, or main-thread work. Lock-free counters expose callback, packet, byte, native-status, conversion, and completed-frame progress to opt-in diagnostics without retaining audio content. Complete frames enter a fixed four-frame queue. Overflow clears stale frames, faults the backend session, and allows a later fresh frame to reconnect rather than allowing unbounded latency or memory.

### Session

Start is transactional:

1. validate endpoint and selected source;
2. authorize the relevant capture permission;
3. authenticate when a password is present;
4. connect WebSocket;
5. reset subtitle state and send `start` with an explicit `asr_context_terms` array;
6. start capture;
7. publish Running.

Every failed stage rolls back later stages. A backend rejection observed during startup prevents or stops capture and returns the operator to Stopped. A socket close, receive error, later backend error, failed audio send, queue overflow, or at least eight minutes without an audio callback marks the backend faulted. The next fresh frame performs one mutually exclusive reconnect and resumes with a new start message carrying the same immutable hotword snapshot. `started` metadata reports `Running · Hotwords: N`; a legacy acknowledgement without metadata reports `Running · Hotwords not confirmed` for a nonempty request.

Stop is shared and idempotent. It stops capture, drains/cancels audio work, sends `finish` for a healthy connected backend, waits up to 120 seconds for `final` or backend error, disconnects, and publishes Stopped. Concurrent Stop/quit requests join the same work.

### Operator and overlay

`OperatorModel` is isolated to the main actor. It loads settings, an optional matching Keychain password, and environment overrides; observes audio/display catalogs; automatically persists raw hotword input; validates it before Start; constructs credentials only inside Start; saves an opted-in password only after successful startup; maps session outputs; and sends subtitle snapshots through the coalescing pump.

`OperatorView` uses a compact two-column SwiftUI hierarchy with no scroll container. `OperatorWindowLayout` selects a 1020 × 540-point preferred size, enforces a 900 × 500-point minimum, and caps the initial window to the active display's visible frame so every setting and action remains visible together.

The overlay is a borderless nonactivating transparent `NSPanel` at `.screenSaver` level. It ignores mouse events and uses `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`, and `.ignoresCycle`. Bilingual text uses PingFang SC Semibold/Medium with natural font-metric line heights. Its Core Text renderer draws a luminance-adaptive black-or-white outline, sized to seven percent of the selected font within a 1.6–3.6-point range, adds a zero-offset dark halo, and then draws the solid fill. This keeps Chinese and Latin glyphs distinguishable even when the selected text color matches the video without covering the picture with an opaque subtitle panel. In the translation region only, the stable history is blended 12% toward black and the model's complete `activePrimaryText` range is blended 6% toward white. Default-white history therefore becomes light gray while the latest sentence remains white; colored choices gain the same relative hierarchy. The range comes from the structured model rather than a string diff, so backend rewrites keep the whole active sentence highlighted without character-level flicker. There is no animation or additional setting. Before any target-text relayout, the view captures whether the reader is following the newest edge. Both an append and a structural active-tail correction continue following when that intent was active; both preserve the clip-view position when the reader deliberately scrolled up. This prevents an added wrapped line from stranding the viewport above all later translations. The target and reference text views also expose stable accessibility identifiers and current text values for local assistive technology and autonomous live verification. Persistent display selection uses a CG display UUID, so array order and transient display IDs are irrelevant.

### Persistence and diagnostics

`SettingsStore` normalizes values, strips URL credentials/sensitive query parameters, removes legacy `AuthPassword`, preserves raw `AsrContextTermsText` and unrelated JSON fields, and uses mode-0700 directories plus atomic mode-0600 files. No password field exists in `AppSettings`. `KeychainPasswordStore` is the sole persistent password boundary and uses the native Security framework's generic-password operations.

`DiagnosticsLogger` is disabled by default. When enabled, it permanently redacts credentials, cookies, usernames, device identities, and credential-shaped content. It records only hotword counts/character counts/acknowledgement metadata and backend error-message length, never the configured term array or error text. Transcripts remain redacted unless separately opted in.

### Application lifecycle

`AppEnvironment.live()` creates and retains the complete dependency graph once. Launch displays an empty overlay immediately. Termination returns `.terminateLater`; one shared task stops the coordinator, observers, audio units, taps, aggregate devices, and overlay before replying to AppKit.

## Concurrency model

- UI, display state, and overlay operations: `@MainActor`.
- WebSocket/client and session state: Swift actors.
- Capture services: Swift actors around native resources.
- Real-time transfer: lock-bounded native/ring structures with no suspension.
- Disk writes: synchronous private atomic settings writes initiated from operator changes.

The package compiles in Swift 6 mode with complete strict-concurrency checking and warnings treated as errors.
