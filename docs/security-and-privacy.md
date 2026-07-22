# Security and privacy

## Authentication secret handling

VoxHalo provides explicit, opt-in password persistence through macOS Keychain. The app reads one generic-password item at launch and restores it only when its endpoint and username match the current safe settings. It writes or updates that item only after a successful authenticated Start while **Save in Keychain** is enabled. Clearing the checkbox deletes it. A rejected login never replaces the last successful item.

Without that opt-in—or when `VOXBRIDGE_AUTH_PASSWORD` is supplied to a development launch—the password exists only in the operator model and active in-memory session configuration. Credentials are constructed only when Start is invoked.

The app never writes the password to:

- `settings.json`;
- diagnostics or transcript logs;
- the application bundle;
- crash/status text produced by VoxHalo.

The settings JSON persists username only. Loading old JSON removes every case-insensitive `AuthPassword` key before rewriting it. URL sanitation removes userinfo, fragments, and credential-shaped query items. The Keychain item uses `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; it is local to this Mac and is not a configuration-file or bundle resource.

Because the local release is ad hoc signed, rebuilding changes its code identity and macOS may request Keychain access again. Normal relaunches of the unchanged final bundle reuse the saved password without re-entry.

## Transport

The public default uses TLS (`wss://`). Authentication derives an HTTPS `/login` request from a WSS endpoint and transfers returned cookies only to the ephemeral WebSocket handshake. URLSession cookie stores and caches are disabled.

For compatibility with user-selected local Windows deployments, `ws://` is accepted and `NSAppTransportSecurity.NSAllowsArbitraryLoads=true` is present. This weakens transport policy for endpoints selected by the operator, so the UI warns that `ws://` is not encrypted. Do not use insecure WebSockets across an untrusted network.

Authentication failures reveal no username, password, cookie, response body, or credential-bearing URL. Other HTTP failures expose status code only.

## Capture permissions

Hardware input uses macOS Microphone permission. Global output capture uses Screen & System Audio Recording permission through a private Core Audio tap. Info.plist includes clear usage descriptions. The local signature includes only the audio-input entitlement and deliberately excludes App Sandbox for this local release.

If permission is denied:

1. stop the session;
2. use the operator's Settings link, or open **System Settings → Privacy & Security**;
3. enable VoxHalo under **Microphone** or **Screen & System Audio Recording**;
4. quit and relaunch if macOS requests it;
5. retry Start.

Permission approval is associated with the app identity/signature. Rebuilding an ad hoc-signed bundle can cause macOS to ask again. Run final checks against one unchanged build.

## Hotword data

- Hotwords can contain personal names, organization/customer names, or internal terminology and must be treated as potentially identifying data.
- Raw input is automatically stored as plaintext in `AsrContextTermsText` under `~/Library/Application Support/VoxHalo/settings.json`.
- The validated list is sent to the operator-selected VoxBridge backend on the initial `start` and on every backend-session reconnect.
- Diagnostics never receive or write the configured list or backend error-message text. They receive only counts, Unicode character totals, acknowledgement metadata, and error-message length.
- With transcript diagnostics explicitly enabled, recognized or translated text can naturally contain the same words. That is opted-in subtitle content, not a hotword configuration field.
- Stop the session before editing or clearing hotwords. Clearing persists an empty string and the next Start explicitly sends an empty array.

## Diagnostics redaction

Diagnostics are off by default. When opted in, allowed metadata includes endpoint host/port, event type, sequence, lengths, stability fields, hotword count/character/activation metadata, nonsecret categories, aggregate frame/byte counts, and audio-pipeline stage counters plus native status codes. Pipeline diagnostics never contain captured samples.

Permanent redactions apply even when transcript logging is separately enabled:

- password and form/cookie/authorization material;
- authentication username;
- hardware device name and persistent UID;
- credential-shaped endpoint or error text.

Recognition and translation bodies are redacted by default and appear only under the explicit transcript opt-in. Diagnostics failures are ignored so logging cannot disrupt capture or shutdown.

## Local files

Application Support and Logs directories are mode `0700`. Settings and diagnostics files are mode `0600`. Settings writes are atomic. The release bundle contains only the executable, Info.plist, empty Resources directory, and code-signature material; it does not package settings, logs, source, tests, Windows files, or runtime credentials.

## Signing and distribution boundary

`scripts/build-app.sh` creates a Release arm64 bundle and signs it ad hoc with Hardened Runtime plus `com.apple.security.device.audio-input=true`. `scripts/verify-app.sh` checks metadata, architecture, signature flags, entitlements, and bundle privacy.

Ad hoc signing is suitable only for this Mac. The bundle is not notarized and is not intended for third-party distribution. Developer ID signing, notarization, App Store sandboxing, Intel support, and automatic updates are out of scope.

## Backend boundary

VoxHalo sends captured audio and validated hotword context, then receives subtitle events from the configured VoxBridge service. It does not operate or modify that backend, control backend logging/retention, or run recognition/translation locally. Operators should use only a backend whose data-handling policy they accept.
