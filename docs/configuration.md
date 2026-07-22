# Configuration

## Operator controls

The operator window exposes:

- VoxBridge endpoint and authentication username/password;
- exactly Chinese → English and English → Chinese;
- System Audio plus currently available hardware input devices;
- persistent display selection;
- Start, Stop, state, and concise recovery messages;
- target and reference subtitle height, font, offset, and color.

Endpoint, username, direction, and audio source are locked while starting/running/finishing. Display and layout stay live. Start requires a stopped state, valid WebSocket endpoint, and available source. Stop is available only while starting or running.

## Backend endpoint

Default:

```text
wss://ushome.amycat.com:18024/ws
```

Only absolute `ws://` or `wss://` URLs with a host are accepted. `ws://` works for parity with local Windows deployments, but the UI displays `ws:// is not encrypted`. Prefer TLS (`wss://`).

Before persistence, URL userinfo and fragments are removed. Query items named `token`, `access_token`, `refresh_token`, `id_token`, `session_token`, `api_key`, `apikey`, `password`, `passwd`, `secret`, `client_secret`, or `authorization` are removed case-insensitively. The legacy private endpoint `ws://192.168.1.31:8024/ws` normalizes to the public default.

## Authentication

Enter the password in the SecureField before Start. A blank password skips the `/login` request. A nonblank password causes form authentication and cookie handoff to the WebSocket.

The username may be persisted. The password is memory-only: it is not part of `AppSettings`, settings JSON, logs, Keychain, or the application bundle. It must normally be re-entered after relaunch.

Command-line development launches may override the fields:

```text
VOXBRIDGE_AUTH_USERNAME
VOXBRIDGE_AUTH_PASSWORD
```

Environment values take precedence over saved/default values. The environment password still remains memory-only. Finder launches should not be expected to inherit shell environment variables.

## Audio and display fallback

System Audio is the default source. A saved hardware UID is restored only when it still exists. If missing before Start, selection falls back to System Audio, otherwise the first available source. If the active hardware source disappears, the running session stops with a disconnect message; it never silently switches live input.

The saved display is a persistent CG display UUID. If unavailable, the main display is selected, otherwise the first available display. The overlay responds to attach/remove/rearrange/rename events and fills the selected screen in points, including Retina and negative-coordinate arrangements.

## Subtitle layout

| Setting | Default | Range |
|---|---:|---:|
| Target area height | 264 pt | 120–640 pt |
| Target font | 36 pt | 18–56 pt |
| Target top offset | 0 pt | 0–900 pt |
| Reference area height | 96 pt | 48–360 pt |
| Reference font | 24 pt | 16–42 pt |
| Reference bottom offset | 0 pt | 0–900 pt |

Colors are exactly White `#FFFFFF`, Soft White `#F4F4F4`, Warm Yellow `#FFD966`, Cyan `#8FE8FF`, Soft Green `#B7F7C4`, and Pink `#FFB3D1`. Defaults are White target and Soft White reference.

## Settings file

```text
~/Library/Application Support/VoxHalo/settings.json
```

The directory is mode `0700`; the JSON file is mode `0600`. Writes use a private temporary file, synchronization, atomic rename, and permission reapplication. Unknown fields are retained. Malformed or unreadable data produces safe defaults and a concise operator warning instead of preventing launch.

## Diagnostics

Diagnostics are disabled unless:

```text
TRANSLATEPCCS_DIAGNOSTICS=1
```

When enabled, the mode-0600 log is:

```text
~/Library/Logs/VoxHalo/client.log
```

Transcript bodies remain redacted unless both diagnostics and this separate opt-in are set:

```text
TRANSLATEPCCS_DIAGNOSTIC_TRANSCRIPTS=1
```

Even with transcript opt-in, passwords, cookies, authorization values, usernames, device names, device UIDs, and credential-shaped material are always redacted.
