# User guide

## Launch

Build once with `scripts/build-app.sh`, then open `dist/VoxHalo.app`. An empty transparent overlay appears immediately and the operator window presents session, display, layout, status, Start, and Stop controls.

The overlay never accepts focus or mouse clicks. You continue interacting with the application underneath it.

## Start a subtitle session

1. Confirm the VoxBridge endpoint. The default is the TLS endpoint `wss://ushome.amycat.com:18024/ws`.
2. Enter the username and password required by the service. The password is not saved.
3. Choose **Chinese → English** or **English → Chinese**.
4. Choose **System Audio** for audio playing on the Mac, or select a microphone/USB/line input.
5. Choose the display that should carry subtitles.
6. Adjust translation and recognition layout if desired.
7. Click **Start**.

While starting/running/finishing, the endpoint, login, direction, and source are locked to preserve a transactional session. Display and layout controls remain live.

## macOS permissions

### Hardware input

The first microphone/input session can request Microphone access. Choose **Allow**. If denied, use **Open Microphone Settings**, enable VoxHalo in **Privacy & Security → Microphone**, and retry.

### System Audio

The first global-output session can request Screen & System Audio Recording access. Choose **Allow**. If denied, use the offered Settings link, enable VoxHalo in **Privacy & Security → Screen & System Audio Recording**, and retry. macOS may require relaunching the app.

Because this release is locally signed, rebuilding may cause permission approval to be requested again.

## Overlay and layout

The upper region displays translated target text as a continuous outlined stream. The lower region displays recent recognized source/reference text. Both regions auto-scroll to the newest bounded content.

You can change these while running:

- target/reference area height;
- target/reference font size;
- target top or reference bottom offset;
- either fixed color choice;
- selected display.

The overlay follows display UUIDs, supports displays to the left/below the main screen, uses point geometry on Retina displays, joins all Spaces, and stays visible as a full-screen auxiliary panel.

## Stop and recovery

Click **Stop** to end capture and ask the backend to finalize. VoxHalo waits for a final response for up to 120 seconds, then disconnects and returns to Stopped. Stop is disabled while finalization is already in progress.

If the socket/backend/audio send fails, the last stable subtitle stays visible. The next fresh audio frame performs a single reconnect. If audio callbacks disappear for at least eight minutes, the same recovery is used. Queue overload drops stale queued audio and reconnects before a fresh frame rather than accumulating delay.

If an active hardware device is unplugged, the session stops with a concise message. It does not switch a live session to another microphone. Once stopped, selection falls back safely.

## Status messages

- **Authentication failed**: check username/password; no entered value is echoed.
- **Microphone access is required**: enable Microphone privacy access.
- **System Audio Recording access is required**: enable Screen & System Audio Recording access.
- **Selected audio source was disconnected/unavailable**: reconnect it or select another source while stopped.
- **Audio pipeline overloaded**: playback/network latency exceeded the bounded queue; the session will recover on a fresh frame.
- **Final wait timeout**: no final backend response arrived within 120 seconds; cleanup still completes.
- **ws:// is not encrypted**: endpoint traffic is plaintext; use `wss://` when possible.

## Persistence and relaunch

Endpoint, username, direction, selected source/display, layout, and colors persist in the private settings JSON. Missing source/display selections fall back at launch. The password must be entered again after a normal Finder relaunch unless a command-line development environment supplies it.

To remove saved preferences, quit VoxHalo and delete:

```text
~/Library/Application Support/VoxHalo/settings.json
```

Do not place a password in this file; legacy password keys are removed automatically.

## Quit

Quit normally from the app menu or Dock. VoxHalo delays termination until it has stopped the session, observers, Core Audio unit, process tap, and private aggregate device, then closes the overlay.
