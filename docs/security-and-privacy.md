# Security and privacy

## Authentication secret handling

VoxHalo deliberately provides no password persistence. The password exists only in the operator model and active in-memory session configuration after the user enters it or supplies `VOXBRIDGE_AUTH_PASSWORD` to a development launch. Credentials are constructed only when Start is invoked.

The app never writes the password to:

- `settings.json`;
- diagnostics or transcript logs;
- Keychain/Security framework storage;
- the application bundle;
- crash/status text produced by VoxHalo.

The persisted authentication field is username only. Loading old JSON removes every case-insensitive `AuthPassword` key before rewriting it. URL sanitation removes userinfo, fragments, and credential-shaped query items.

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

## Diagnostics redaction

Diagnostics are off by default. When opted in, allowed metadata includes endpoint host/port, event type, sequence, lengths, stability fields, nonsecret categories, and aggregate frame/byte counts.

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

VoxHalo sends captured audio and receives subtitle events from the configured VoxBridge service. It does not operate or modify that backend and does not run recognition/translation locally. Operators should use only a backend whose data-handling policy they accept.
