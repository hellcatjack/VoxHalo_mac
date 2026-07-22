# VoxHalo final manual acceptance

Run this checklist against one unchanged `dist/VoxHalo.app`. Do not rebuild after recording the signature hash or granting permissions. Mark exactly one result per applicable row. If required external hardware is unavailable, mark N/A and retain the automated catalog proof; do not mark it Pass.

Never record the authentication password or real identifying hotwords here. If an audio device UID is needed for manual correlation, record it only in this checklist—not application settings screenshots or diagnostics.

## Build record

| Field | Recorded value |
|---|---|
| Date/time and timezone | 2026-07-22 12:06 EDT (-0400) |
| macOS version/build | 26.5.2 (25F84) |
| Hardware/model | MacBook Air Mac16,12; Apple M4; 24 GB |
| Xcode version/build | Xcode 26.6 (17F113) |
| Swift version | Apple Swift 6.3.3; target arm64-apple-macosx26.0 |
| App Git commit | `a4e36bef29cddb61722a8e94e9b01a25eeff32d9` (the committed source tree used by the recorded executable) |
| Windows reference commit | `0867afe48e2196e84512c842aacb6117a1f8799e` |
| Bundle path | `dist/VoxHalo.app` |
| Bundle identifier | `com.hellcatjack.voxhalo` |
| Executable architecture | arm64 only; executable SHA-256 `5a1eef34cade58a3db235046cf38d099e0e3080af46960d12bde2a54ee06d3f3` |
| App icon | Official PCCS square source SHA-256 `952e3bf721b3746565b2d01b4a47a0788dfb3a5076fae1663f63285d017fc34d`; bundled ICNS SHA-256 `f5d655b541ac71ea9b10df11506a1f81f9e83a05a474f999fbe23a6cf2b7f377` |
| Code-signature CDHash | `e577e29c7efa6a0166ebe8dfb1ddf151c7ce98e2`; ad hoc + runtime |
| Endpoint (no userinfo/token) | `wss://ushome.amycat.com:18024/ws` |
| Tested audio device UID (outside logs only) | System Audio synthetic source; no external hardware UID recorded |
| Tester | Codex + local operator |

Result notation in each row: `[ ] Pass  [ ] Fail  [ ] N/A`.

## A. Automated and bundle gate

1. `[x] Pass  [ ] Fail  [ ] N/A` Full `swift test` succeeds. Evidence/notes: 335 tests, two intentionally environment-gated tests skipped, zero failures.
2. `[x] Pass  [ ] Fail  [ ] N/A` Complete strict-concurrency build with warnings as errors succeeds. Evidence/notes: 335 tests, zero failures/warnings; the live diagnostic gate was also exercised separately for both ten-minute runs and the current incident slice.
3. `[x] Pass  [ ] Fail  [ ] N/A` Opt-in packaging test builds and verifies the release bundle. Evidence/notes: 11/11 ProjectPackagingTests passed with `VOXHALO_RUN_PACKAGING_TESTS=1`.
4. `[x] Pass  [ ] Fail  [ ] N/A` `scripts/verify-app.sh dist/VoxHalo.app` confirms plist/icon metadata, valid ICNS with a 1024-pixel representation, arm64, signature, Hardened Runtime, audio-input entitlement, absent sandbox, and clean payload. Evidence/notes: verifier passed on recorded CDHash.
5. `[x] Pass  [ ] Fail  [ ] N/A` Bundle launches cleanly and reports no immediate crash. Evidence/notes: LaunchServices registered the new arm64 process on the unlocked GUI session; `NSWorkspace` loaded and rendered the bundled PCCS mark with the macOS system icon mask. Access to the previously saved password was gated by the expected one-time macOS login-Keychain authorization for the new ad-hoc CDHash; automation cancelled it without changing access policy, terminated the process, and left zero VoxHalo or SecurityAgent processes afterward.

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
15. `[x] Pass  [ ] Fail  [ ] N/A` Actual playing Mac system output—not silence—produces live activity through System Audio. Evidence: two exact `qXYBIUSajQw` 18:00–28:00 plays reached media times 1679.872 and 1679.873 seconds. Round one produced 60,339 callbacks and 2,011 delivered 10,240-byte frames; round two remained continuous through 2,230 delivered frames including its delayed shutdown tail.
16. `[x] Pass  [ ] Fail  [ ] N/A` Captured output is 16,000 Hz, signed PCM16 little-endian, mono, in exact 10,240-byte/320 ms frames. Evidence: conversion, AUHAL, tap, accumulator, endianness, exact-frame, and capture integration tests passed.
17. `[x] Pass  [ ] Fail  [ ] N/A` Capture/translation remains responsive under a burst; memory and pending audio stay bounded. Evidence: the two ten-minute runs produced 1,812 and 1,795 partial events, zero ring-write failures, native status 0, one final each, and no capture/backend failure.

## D. Real backend and subtitle semantics

18. `[x] Pass  [ ] Fail  [ ] N/A` Authenticated Chinese → English session reaches Running and displays English target plus Chinese reference. Evidence: the previously approved unchanged signed bundle completed both ten-minute real backend/system-audio runs; the new committed production store and renderer replayed both complete event slices into visually inspected bilingual pixel snapshots.
19. `[ ] Pass  [ ] Fail  [ ] N/A` Authenticated English → Chinese session reaches Running and displays Chinese target plus English reference. Notes: Pending.
20. `[ ] Pass  [ ] Fail  [ ] N/A` Wrong authentication is rejected without exposing username/password/cookie/body, then correct credentials recover. Notes: Pending.
21. `[x] Pass  [ ] Fail  [ ] N/A` Partial reference updates do not rewrite already stable target translation. Evidence: every explicit source revision may refresh only the active tail; every earlier segment and the simulated reader's scroll origin remained unchanged across both real ten-minute replays and the current incident replay.
22. `[x] Pass  [ ] Fail  [ ] N/A` Committed/updated/late translations retain stable ordering and continuous target text. Evidence: the two ten-minute slices contained 67/62 commits, 67/60 updates, 133/120 sentence translations, and one final each. Of 123 matched translations that were still active, all 123 appeared immediately in the production display model. The current live incident slice contained 16 commits, 27 updates, 43 translations, and one final; all 27/27 matched active translations appeared immediately, and the rendered/final longest-common subsequence was 373/373 words. During its exact replay, every event containing both history and an active tail retained a latest/history relative-luminance gap greater than 0.40. Sequence-aware overlap tests prove a late older response cannot hide the newest revision. Final rendered coverage was 98.2%, 100%, and 100% respectively.
23. `[ ] Pass  [ ] Fail  [ ] N/A` Backend/socket interruption preserves stable text; next fresh frame performs one reconnect and resumes. Notes: Pending.
24. `[x] Pass  [ ] Fail  [ ] N/A` Eight-minute callback-gap recovery behavior is exercised or explicitly covered by the deterministic clock test. Notes: deterministic session-clock recovery tests passed at the exact 480-second boundary.
25. `[x] Pass  [ ] Fail  [ ] N/A` Normal Stop sends finish, receives final, and returns Stopped. Evidence: both ten-minute sessions received one final and disconnected without a failure; round one returned through Stop and round two exercised the shared quit/Stop teardown after the automation window closed.
26. `[ ] Pass  [ ] Fail  [ ] N/A` Missing final response reaches the 120-second timeout, cleans up, and returns Stopped. Notes: Pending.

## E. Overlay, displays, Spaces, and interaction

27. `[x] Pass  [ ] Fail  [ ] N/A` Empty overlay appears at launch before a session. Evidence: a full-display layer-1000 VoxHalo panel appeared on both clean launches.
28. `[x] Pass  [ ] Fail  [ ] N/A` Overlay is transparent, target above reference, outlined/readable over both bright and dark content. Evidence: an actual AppKit comparison board rendered white-on-white, yellow-on-yellow, and cyan-on-cyan bilingual subtitles, with `#C2C2C2` default history followed by `#FFFFFF` newest text. Every panel passed the dark-edge pixel threshold and was visually inspected; all six target palette choices passed a greater-than-0.28 luminance-gap assertion, and the current real-session follower snapshot was inspected on black. The font-scaled adaptive outline and soft halo remain local to glyphs, so no opaque video-covering band was introduced.
29. `[ ] Pass  [ ] Fail  [ ] N/A` Overlay is click-through and never steals keyboard focus from the underlying app.
30. `[ ] Pass  [ ] Fail  [x] N/A` Main and secondary display selection moves the visible overlay immediately and persists by UUID. Notes: only the built-in display is attached; UUID/move/persistence is covered automatically.
31. `[ ] Pass  [ ] Fail  [x] N/A` Negative-coordinate display placement fills the intended screen in points. Notes: no secondary display is attached; negative-coordinate geometry is covered automatically.
32. `[x] Pass  [ ] Fail  [ ] N/A` Retina scale does not double/halve overlay geometry or layout values. Evidence: built-in Retina logical bounds filled by the layer-1000 panel; scale/point tests passed.
33. `[ ] Pass  [ ] Fail  [x] N/A` Removing the selected display moves the overlay to the main/first available display. Notes: no removable display is attached; removal fallback is covered automatically.
34. `[ ] Pass  [ ] Fail  [ ] N/A` Overlay remains visible across Spaces and as an auxiliary panel above a full-screen app.
35. `[ ] Pass  [ ] Fail  [ ] N/A` Target height/font/top offset/color update live while Running.
36. `[ ] Pass  [ ] Fail  [ ] N/A` Reference height/font/bottom offset/color update live while Running.
37. `[x] Pass  [ ] Fail  [ ] N/A` Burst subtitle updates coalesce without freezing scrolling or the operator window. Evidence: live sampling during the reported freeze showed the capture, WebSocket receive loop, state store, and translation events continuing. The renderer had preserved the old absolute scroll origin during a structural correction: in the regression, it remained at 3,186 points after the new bottom moved to 7,182 points, making every later translation appear frozen. The view now captures follow intent before relayout, keeps a follower at the newest edge for both corrections and appends, and still preserves a deliberately scrolled-up reader. The exact 1,043-line incident slice passed this invariant after every event, while both pixel snapshots showed the intended position. The client apply budget remains 80 ms.

## F. Persistence, diagnostics, teardown, and relaunch

38. `[ ] Pass  [ ] Fail  [ ] N/A` Safe endpoint, username, direction, source, display, and all layout values survive relaunch.
39. `[ ] Pass  [ ] Fail  [ ] N/A` With Save in Keychain enabled, a successful Start restores the matching password after unchanged-bundle relaunch; clearing it removes the item. Evidence: the prior unchanged bundle restored the saved item without a prompt, but this newly rebuilt ad-hoc signature requires one macOS Keychain authorization before the check can be repeated. No credential material entered settings, diagnostics, bundle resources, or launch arguments.
40. `[x] Pass  [ ] Fail  [ ] N/A` Saved missing audio source falls back before Start; active source removal never switches during Running. Evidence: operator/catalog/disconnect tests passed.
41. `[x] Pass  [ ] Fail  [ ] N/A` Saved missing display falls back to main/first display. Evidence: display catalog and overlay removal tests passed.
42. `[x] Pass  [ ] Fail  [ ] N/A` Diagnostics are absent/off by default. Evidence: no `~/Library/Logs/VoxHalo/client.log` after clean launches; opt-in test passed.
43. `[x] Pass  [ ] Fail  [ ] N/A` Diagnostics opt-in creates private mode-0600 output with transcripts redacted by default. Evidence: private JSON-lines logger tests passed.
44. `[x] Pass  [ ] Fail  [ ] N/A` Transcript opt-in still permanently redacts credential, username, device name, device UID, cookie, and authorization material. Evidence: permanent redaction and credential-shaped-content tests passed.
45. `[x] Pass  [ ] Fail  [ ] N/A` Settings/log directories are mode 0700 and files are mode 0600. Evidence: persistence and diagnostics permission tests passed; runtime diagnostics remain absent by default.
46. `[x] Pass  [ ] Fail  [ ] N/A` Stop destroys active AUHAL/tap/private aggregate resources; repeated Stop is harmless. Evidence: native cleanup/retry/concurrent-Stop tests passed and clean-launch quit left no VoxHalo aggregate/tap.
47. `[ ] Pass  [ ] Fail  [ ] N/A` Quit during Starting, Running, and Finishing shares cleanup and leaves no private tap/aggregate device.
48. `[ ] Pass  [ ] Fail  [ ] N/A` The unchanged signed bundle relaunches and completes a smoke session with expected permission state. Evidence: the new bundle passed process/window/clean-quit smoke testing, but a new live Start remains pending the one-time Keychain authorization required by its new ad-hoc CDHash.

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

Blocking rows / notes: Two exact YouTube 18:00–28:00 Chinese → English runs pass audio continuity, backend finalization, 100% immediate reflection for all 123 matched active revisions, frozen-history/scroll stability, and 98.2%/100% rendered-final coverage. The exact current freeze incident additionally passes 27/27 immediate active-translation reflection, 373/373 rendered-final words, bottom-follow after every event, and preserved scrolled-reader position under the repaired renderer. The rebuilt local-only bundle still needs one macOS login-Keychain authorization because its ad-hoc CDHash changed; repeat live Start and unchanged-bundle relaunch remain pending after that one-time system approval. Unrelated hardware-input, second-direction, multi-display/Spaces, permission-denial, and destructive timeout rows remain pending or N/A as marked.
