# VoxHalo final manual acceptance

Run this checklist against one unchanged `dist/VoxHalo.app`. Do not rebuild after recording the signature hash or granting permissions. Mark exactly one result per applicable row. If required external hardware is unavailable, mark N/A and retain the automated catalog proof; do not mark it Pass.

Never record the authentication password or real identifying hotwords here. If an audio device UID is needed for manual correlation, record it only in this checklist—not application settings screenshots or diagnostics.

## Build record

| Field | Recorded value |
|---|---|
| Date/time and timezone | 2026-07-22 01:17 EDT (-0400) |
| macOS version/build | 26.5.2 (25F84) |
| Hardware/model | MacBook Air Mac16,12; Apple M4; 24 GB |
| Xcode version/build | Xcode 26.6 (17F113) |
| Swift version | Apple Swift 6.3.3; target arm64-apple-macosx26.0 |
| App Git commit | `a560d74dd1868cc4ca91a7a15acf62e2c9e0c154` (the committed source tree used by the recorded executable) |
| Windows reference commit | `0867afe48e2196e84512c842aacb6117a1f8799e` |
| Bundle path | `dist/VoxHalo.app` |
| Bundle identifier | `com.hellcatjack.voxhalo` |
| Executable architecture | arm64 only; executable SHA-256 `df377037f67b55580e29054355dd4c6bd1fe7c1a699adef7126709e3f03ff095` |
| Code-signature CDHash | `4c1e9b3d2a33fd9559b3f29c43b09dd27a6062f7`; ad hoc + runtime |
| Endpoint (no userinfo/token) | `wss://ushome.amycat.com:18024/ws` |
| Tested audio device UID (outside logs only) | System Audio synthetic source; no external hardware UID recorded |
| Tester | Codex + local operator |

Result notation in each row: `[ ] Pass  [ ] Fail  [ ] N/A`.

## A. Automated and bundle gate

1. `[x] Pass  [ ] Fail  [ ] N/A` Full `swift test` succeeds. Evidence/notes: 321 tests, two intentionally environment-gated tests skipped, zero failures.
2. `[x] Pass  [ ] Fail  [ ] N/A` Complete strict-concurrency build with warnings as errors succeeds. Evidence/notes: 321 tests, zero failures/warnings; both gated tests were also exercised separately where applicable.
3. `[x] Pass  [ ] Fail  [ ] N/A` Opt-in packaging test builds and verifies the release bundle. Evidence/notes: 10/10 ProjectPackagingTests passed with `VOXHALO_RUN_PACKAGING_TESTS=1`.
4. `[x] Pass  [ ] Fail  [ ] N/A` `scripts/verify-app.sh dist/VoxHalo.app` confirms plist, arm64, signature, Hardened Runtime, audio-input entitlement, absent sandbox, and clean payload. Evidence/notes: verifier passed on recorded CDHash.
5. `[x] Pass  [ ] Fail  [ ] N/A` Bundle launches cleanly and reports no immediate crash. Evidence/notes: LaunchServices registered the foreground arm64 process, it remained alive through the smoke interval, and an AppleEvent clean quit completed.

## B. Permission grant, denial, and recovery

6. `[ ] Pass  [ ] Fail  [ ] N/A` With Microphone permission not determined, hardware Start prompts and Allow reaches Running. Notes: Pending.
7. `[ ] Pass  [ ] Fail  [ ] N/A` With Microphone permission denied, Start returns Stopped with concise guidance and a working Settings link. Notes: Pending.
8. `[ ] Pass  [ ] Fail  [ ] N/A` Enabling Microphone permission in System Settings and retrying recovers without reinstalling. Notes: Pending.
9. `[ ] Pass  [ ] Fail  [ ] N/A` With Screen & System Audio Recording permission not determined, System Audio Start prompts and Allow reaches Running. Notes: Pending.
10. `[ ] Pass  [ ] Fail  [ ] N/A` With System Audio permission denied, Start returns Stopped with concise guidance and a working Settings link. Notes: Pending.
11. `[ ] Pass  [ ] Fail  [ ] N/A` Enabling System Audio permission and retrying/relaunching recovers. Notes: Pending.

## C. Real capture and PCM

12. `[ ] Pass  [ ] Fail  [ ] N/A` Built-in microphone produces live reference/subtitle activity. Notes: Pending.
13. `[ ] Pass  [ ] Fail  [x] N/A` Available USB/line input appears by name and produces live activity. Notes: no USB/line input is attached; built-in microphone and speakers are the only enumerated devices, while catalog behavior is covered automatically.
14. `[ ] Pass  [ ] Fail  [ ] N/A` Unplugging the active external input stops with a disconnect message and does not switch live source. Notes: Pending.
15. `[x] Pass  [ ] Fail  [ ] N/A` Actual playing Mac system output—not silence—produces live activity through System Audio. Evidence: the exact `qXYBIUSajQw` 18:00–20:00 audio segment produced 13,604 callbacks and 453 delivered 10,240-byte frames.
16. `[x] Pass  [ ] Fail  [ ] N/A` Captured output is 16,000 Hz, signed PCM16 little-endian, mono, in exact 10,240-byte/320 ms frames. Evidence: conversion, AUHAL, tap, accumulator, endianness, exact-frame, and capture integration tests passed.
17. `[x] Pass  [ ] Fail  [ ] N/A` Capture/translation remains responsive under a burst; memory and pending audio stay bounded. Evidence: 272 partial events completed with zero ring-write failures, native status 0, one final, and a normal Stop.

## D. Real backend and subtitle semantics

18. `[x] Pass  [ ] Fail  [ ] N/A` Authenticated Chinese → English session reaches Running and displays English target plus Chinese reference. Evidence: the unchanged signed bundle completed the two-minute real backend/system-audio run and its production renderer replay produced the bilingual pixel snapshot.
19. `[ ] Pass  [ ] Fail  [ ] N/A` Authenticated English → Chinese session reaches Running and displays Chinese target plus English reference. Notes: Pending.
20. `[ ] Pass  [ ] Fail  [ ] N/A` Wrong authentication is rejected without exposing username/password/cookie/body, then correct credentials recover. Notes: Pending.
21. `[x] Pass  [ ] Fail  [ ] N/A` Partial reference updates do not rewrite already stable target translation. Evidence: the live stream contained a structural aggregate correction after a stable sentence update; the client replay preserved every frozen prefix and the simulated reader's scroll origin.
22. `[x] Pass  [ ] Fail  [ ] N/A` Committed/updated/late translations retain stable ordering and continuous target text. Evidence: 18 sentence commits, 19 sentence translations, one sentence update, 272 partials, and final were replayed through the production store and overlay with zero history or scroll-anchor violations.
23. `[ ] Pass  [ ] Fail  [ ] N/A` Backend/socket interruption preserves stable text; next fresh frame performs one reconnect and resumes. Notes: Pending.
24. `[x] Pass  [ ] Fail  [ ] N/A` Eight-minute callback-gap recovery behavior is exercised or explicitly covered by the deterministic clock test. Notes: deterministic session-clock recovery tests passed at the exact 480-second boundary.
25. `[x] Pass  [ ] Fail  [ ] N/A` Normal Stop sends finish, receives final, and returns Stopped. Evidence: the two-minute run received one final, disconnected normally, destroyed capture, and displayed Stopped.
26. `[ ] Pass  [ ] Fail  [ ] N/A` Missing final response reaches the 120-second timeout, cleans up, and returns Stopped. Notes: Pending.

## E. Overlay, displays, Spaces, and interaction

27. `[x] Pass  [ ] Fail  [ ] N/A` Empty overlay appears at launch before a session. Evidence: a full-display layer-1000 VoxHalo panel appeared on both clean launches.
28. `[ ] Pass  [ ] Fail  [ ] N/A` Overlay is transparent, target above reference, outlined/readable over both bright and dark content.
29. `[ ] Pass  [ ] Fail  [ ] N/A` Overlay is click-through and never steals keyboard focus from the underlying app.
30. `[ ] Pass  [ ] Fail  [x] N/A` Main and secondary display selection moves the visible overlay immediately and persists by UUID. Notes: only the built-in display is attached; UUID/move/persistence is covered automatically.
31. `[ ] Pass  [ ] Fail  [x] N/A` Negative-coordinate display placement fills the intended screen in points. Notes: no secondary display is attached; negative-coordinate geometry is covered automatically.
32. `[x] Pass  [ ] Fail  [ ] N/A` Retina scale does not double/halve overlay geometry or layout values. Evidence: built-in Retina logical bounds filled by the layer-1000 panel; scale/point tests passed.
33. `[ ] Pass  [ ] Fail  [x] N/A` Removing the selected display moves the overlay to the main/first available display. Notes: no removable display is attached; removal fallback is covered automatically.
34. `[ ] Pass  [ ] Fail  [ ] N/A` Overlay remains visible across Spaces and as an auxiliary panel above a full-screen app.
35. `[ ] Pass  [ ] Fail  [ ] N/A` Target height/font/top offset/color update live while Running.
36. `[ ] Pass  [ ] Fail  [ ] N/A` Reference height/font/bottom offset/color update live while Running.
37. `[x] Pass  [ ] Fail  [ ] N/A` Burst subtitle updates coalesce without freezing scrolling or the operator window. Evidence: 272 live partial events remained responsive; coalescing, rendered-generation, frozen-prefix, and pinned-reader tests all passed.

## F. Persistence, diagnostics, teardown, and relaunch

38. `[ ] Pass  [ ] Fail  [ ] N/A` Safe endpoint, username, direction, source, display, and all layout values survive relaunch.
39. `[x] Pass  [ ] Fail  [ ] N/A` With Save in Keychain enabled, a successful Start restores the matching password after unchanged-bundle relaunch; clearing it removes the item. Evidence: the unchanged recorded bundle relaunched with no SecurityAgent window, showed Saved in macOS Keychain, and remained free of credential material in settings, diagnostics, bundle resources, and launch arguments.
40. `[x] Pass  [ ] Fail  [ ] N/A` Saved missing audio source falls back before Start; active source removal never switches during Running. Evidence: operator/catalog/disconnect tests passed.
41. `[x] Pass  [ ] Fail  [ ] N/A` Saved missing display falls back to main/first display. Evidence: display catalog and overlay removal tests passed.
42. `[x] Pass  [ ] Fail  [ ] N/A` Diagnostics are absent/off by default. Evidence: no `~/Library/Logs/VoxHalo/client.log` after clean launches; opt-in test passed.
43. `[x] Pass  [ ] Fail  [ ] N/A` Diagnostics opt-in creates private mode-0600 output with transcripts redacted by default. Evidence: private JSON-lines logger tests passed.
44. `[x] Pass  [ ] Fail  [ ] N/A` Transcript opt-in still permanently redacts credential, username, device name, device UID, cookie, and authorization material. Evidence: permanent redaction and credential-shaped-content tests passed.
45. `[x] Pass  [ ] Fail  [ ] N/A` Settings/log directories are mode 0700 and files are mode 0600. Evidence: persistence and diagnostics permission tests passed; runtime diagnostics remain absent by default.
46. `[x] Pass  [ ] Fail  [ ] N/A` Stop destroys active AUHAL/tap/private aggregate resources; repeated Stop is harmless. Evidence: native cleanup/retry/concurrent-Stop tests passed and clean-launch quit left no VoxHalo aggregate/tap.
47. `[ ] Pass  [ ] Fail  [ ] N/A` Quit during Starting, Running, and Finishing shares cleanup and leaves no private tap/aggregate device.
48. `[x] Pass  [ ] Fail  [ ] N/A` The unchanged signed bundle relaunches and completes a smoke session with expected permission state. Evidence: post-relaunch Keychain restore showed Stopped without a prompt; an additional system-audio smoke Start/Stop returned to Stopped.

## G. Hotword context

Use synthetic/nonidentifying terms for this section and remove them afterward.

49. `[ ] Pass  [ ] Fail  [ ] N/A` Enter `Elisha, Qwen3-ASR elisha，U.S.` and confirm the raw multiline text survives relaunch.
50. `[ ] Pass  [ ] Fail  [ ] N/A` Start sends `asr_context_terms` in the deduplicated order `Elisha`, `Qwen3-ASR`, `U.S.`.
51. `[ ] Pass  [ ] Fail  [ ] N/A` A current backend acknowledgement shows `Running · Hotwords: 3`.
52. `[ ] Pass  [ ] Fail  [ ] N/A` A socket or long-idle reconnect sends the identical three-term session snapshot.
53. `[ ] Pass  [ ] Fail  [ ] N/A` A term ending in sentence punctuation blocks startup, leaves capture stopped, and retains editable text.
54. `[ ] Pass  [ ] Fail  [ ] N/A` Exactly 24 terms and 160 joined Unicode characters are accepted; larger inputs are rejected without truncation.
55. `[ ] Pass  [ ] Fail  [ ] N/A` Clearing the editor persists an empty value; the next Start sends `asr_context_terms: []` and shows plain `Running`.
56. `[ ] Pass  [ ] Fail  [ ] N/A` Against a compatible legacy backend that omits context metadata from `started`, a nonempty request shows `Running · Hotwords not confirmed` without breaking subtitles.
57. `[x] Pass  [ ] Fail  [ ] N/A` Automated privacy tests prove configured arrays and backend error text never enter diagnostic fields; only count, joined characters, activation/count/character acknowledgement, and message length are recorded. Transcript opt-in may naturally contain the same spoken word.

## Final disposition

- `[ ] Accepted`
- `[ ] Accepted with N/A hardware rows documented`
- `[ ] Rejected; blocking rows listed below`

Blocking rows / notes: The requested Chinese → English system-audio, subtitle-stability, scrolling, Keychain-relaunch, and YouTube 18:00–20:00 rows pass. Unrelated hardware-input, second-direction, multi-display/Spaces, permission-denial, and destructive timeout rows remain pending or N/A as marked.
