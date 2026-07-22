# User guide

## Launch

Build once with `scripts/build-app.sh`, then open `dist/VoxHalo.app`. An empty transparent overlay appears immediately and the operator window presents session, display, layout, status, Start, and Stop controls.

The overlay never accepts focus or mouse clicks. You continue interacting with the application underneath it.

## Start a subtitle session

1. Confirm the VoxBridge endpoint. The default is the TLS endpoint `wss://ushome.amycat.com:18024/ws`.
2. Enter the username and password required by the service. Select **Save in Keychain** if the app should restore it after relaunch; saving occurs only after a successful Start.
3. Choose **Chinese → English** or **English → Chinese**.
4. Optionally enter rare names, technical vocabulary, or abbreviations in **Hotwords**. Separate entries with spaces, line breaks, English commas, or Chinese commas.
5. Choose **System Audio** for audio playing on the Mac, or select a microphone/USB/line input.
6. Choose the display that should carry subtitles.
7. Adjust translation and recognition layout if desired.
8. Click **Start**.

Hotwords are deduplicated case-insensitively while preserving the first spelling and order. Use individual terms, not full sentences or sentence-ending punctuation. `U.S.`, `Node.js`, and `v1.2` are accepted. A maximum of 24 terms and 160 joined Unicode characters is allowed; invalid input blocks the connection without clearing the editor.

While starting/running/finishing, the endpoint, login, direction, hotwords, and source are locked to preserve a transactional session. Display and layout controls remain live.

## macOS permissions

### Hardware input

The first microphone/input session can request Microphone access. Choose **Allow**. If denied, use **Open Microphone Settings**, enable VoxHalo in **Privacy & Security → Microphone**, and retry.

### System Audio

The first global-output session can request Screen & System Audio Recording access. Choose **Allow**. If denied, use the offered Settings link, enable VoxHalo in **Privacy & Security → Screen & System Audio Recording**, and retry. macOS may require relaunching the app.

Because this release is locally signed, rebuilding may cause permission approval to be requested again.

## Overlay and layout

The upper region displays translated target text as a continuous outlined stream. The lower region displays recent recognized source/reference text. New target content follows the newest edge while the view is already following it; a backend correction preserves the current vertical reading position instead of forcing a jump.

VoxHalo stabilizes translated text locally. Once a newer source sentence appears, earlier rendered translations no longer change even if the backend later revises its canonical result. A punctuation-complete prefix is frozen sooner; only the unfinished tail may receive one structural correction. Append-only growth remains visible, and shorter intermediate rollbacks are ignored. This affects display behavior only and requires no backend change.

You can change these while running:

- target/reference area height;
- target/reference font size;
- target top or reference bottom offset;
- either fixed color choice;
- selected display.

The overlay follows display UUIDs, supports displays to the left/below the main screen, uses point geometry on Retina displays, joins all Spaces, and stays visible as a full-screen auxiliary panel.

## Stop and recovery

Click **Stop** to end capture and ask the backend to finalize. VoxHalo waits for a final response for up to 120 seconds, then disconnects and returns to Stopped. Stop is disabled while finalization is already in progress.

If the socket/backend/audio send fails, the last stable subtitle stays visible. The next fresh audio frame performs a single reconnect and resends the same hotword snapshot captured at Start. If audio callbacks disappear for at least eight minutes, the same recovery is used. Queue overload drops stale queued audio and reconnects before a fresh frame rather than accumulating delay.

If an active hardware device is unplugged, the session stops with a concise message. It does not switch a live session to another microphone. Once stopped, selection falls back safely.

## Status messages

- **Authentication failed**: check username/password; no entered value is echoed.
- **Running · Hotwords: N**: the backend acknowledged N active context terms.
- **Running · Hotwords not confirmed**: the nonempty list was sent, but a legacy backend omitted confirmation metadata; audio/subtitles remain compatible.
- **Hotwords cannot contain… / limited to 24 or 160…**: correct the retained input and retry Start.
- **Start failed: …**: the backend rejected session startup; capture was not left running.
- **Microphone access is required**: enable Microphone privacy access.
- **System Audio Recording access is required**: enable Screen & System Audio Recording access.
- **Selected audio source was disconnected/unavailable**: reconnect it or select another source while stopped.
- **Audio pipeline overloaded**: playback/network latency exceeded the bounded queue; the session will recover on a fresh frame.
- **Final wait timeout**: no final backend response arrived within 120 seconds; cleanup still completes.
- **ws:// is not encrypted**: endpoint traffic is plaintext; use `wss://` when possible.

## Persistence and relaunch

Endpoint, username, raw hotword text, direction, selected source/display, layout, and colors persist in the private settings JSON. Missing source/display selections fall back at launch. Hotwords are plaintext and can include identifying/internal terms, so inspect or clear them before sharing the settings file.

With **Save in Keychain** enabled, a successfully authenticated password is stored in macOS Keychain and restored only for the matching endpoint and username. Clear the checkbox to remove it. The password never appears in settings JSON, diagnostics, or the app bundle. Without the checkbox, it remains in memory only and must be entered after relaunch.

To remove saved preferences, quit VoxHalo and delete:

```text
~/Library/Application Support/VoxHalo/settings.json
```

Do not place a password in this file; legacy password keys are removed automatically. Clearing the Hotwords editor writes an empty value for the next launch and next `start` message.

## Quit

Quit normally from the app menu or Dock. VoxHalo delays termination until it has stopped the session, observers, Core Audio unit, process tap, and private aggregate device, then closes the overlay.
