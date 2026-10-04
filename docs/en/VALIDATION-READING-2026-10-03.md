# Native reading captions and session history validation

**English** | [简体中文](../zh-CN/VALIDATION-READING-2026-10-03.md)

This report records the build 40's native Reading first behavior on 2026-10-03. Real replays of two fixed YouTube excerpts completed successfully: Chinese→English used [LxpvBvDr21Q, 10:00–20:00](https://www.youtube.com/watch?v=LxpvBvDr21Q&t=600s), and English→Chinese used [xCUala5j7aQ, 22:00–25:00](https://www.youtube.com/watch?v=xCUala5j7aQ&t=1320s). Recognition, translation, synthesis and native playback used the production pipeline; the replays did not substitute prepared translation or speech events.

## Completed fixed-excerpt replays

| Measurement | Chinese→English | English→Chinese |
| --- | ---: | ---: |
| Captured source duration | 600 s | 179.999 s |
| Runtime including startup and final drain | 656.0009 s | 194.14646 s |
| PCM chunks received / played | 213 / 213 | 44 / 44 |
| Final native audio buffer | 0 | 0 |
| Recorded live caption cards / changes | 91 | 35 |
| Retained session history entries | 117 | 45 |
| Voiced coverage violations | 0 | 0 |
| Duplicate caption identities | 0 | 0 |
| Caption lead relative to RMS voice onset, minimum | 40.58 ms | 7.25 ms |
| Caption lead relative to RMS voice onset, median | 627.58 ms | 626.9167 ms |
| Caption lead relative to RMS voice onset, maximum | 4038.58 ms | 3321.9167 ms |
| Shortest observed caption-card hold | 1.1135 s | 2.13207 s |

Both source captures completed. PCM sequence numbers were continuous, all received chunks played, and the scheduled frame spans matched the received PCM byte lengths exactly. Finishing returned each session to normal idle without an error or timeout. Previously recorded history remained available after stopping. The English→Chinese run included one accepted `:addition:` speech occurrence; its exact accepted wording was retained once as a Spoken supplement.

Both median leads are close to the intended 0.6-second lead for scheduled audio. The minimum and maximum are observations from these replays, not guaranteed limits; a first packet may appear at nearly the same time as its speech. A frozen card can contain several complete neighboring short sentences, so its later members can appear much earlier than their own speech onset. Long single-chunk sentences paginate by approximate PCM progress, without word alignment. The shortest card lasted 1.1135 seconds: live Reading first follows playback and cannot also promise a fixed minimum reading hold for every card during fast speech.

## Measurement method

**Follow-up coverage correction:** the build 40 replay did not install the App's font/screen layout callbacks. Its logical cards therefore defaulted to fitting on one page. The recorded measurements validate controller selection, not actual pagination or screen drawing. The [build 41 follow-up](VALIDATION-CAPTION-HEAD-2026-10-03.md) adds real geometry, normal AppKit drawing and software mixer recording.

The local [`NativeReadingLeadReplay.swift`](../../VoxBridge/tests/macos/NativeReadingLeadReplay.swift) harness supplied file PCM in real time through the production capture interface. It used `NativeSession`, real ASR/MT/TTS and the native speech player, with Reading first selected. It did not create the visible App subtitle overlay. The caption change uses accepted immutable sentence text and native PCM progress; it does not change model selection, synthesized audio or playback scheduling.

The harness sampled the native presentation clock every 20 ms. Lead measurements compare a caption's first observed appearance with voice onset detected from 10 ms RMS windows of the accepted PCM. The numeric precision above describes the calculated frame/timestamp differences; it does not imply physical screen-to-speaker accuracy to hundredths of a millisecond.

Coverage checks match sentence occurrence identity, revision and source order, and ignore whitespace when matching text. Complete grouped sentences count as covered. An already-scheduled upcoming occurrence inside the intended 600 ms lead window is classified separately as an expected lead transition. Thus zero voiced coverage violations means no sampled unexpected lag, missing occurrence or partial page under this check; it does not mean the screen must always show the currently sounding sentence throughout an intentional early transition.

Reading history retains completed full translations and corrections, including exact accepted incremental speech as **Spoken supplement** when the full translation does not cover it. These entries are retained within the session independently of the live caption cards. They survive stopping and source-ledger reconstruction, and clear at the next session or App relaunch.

## Regression checks

The complete suite passed with **1,395 passed, 32 skipped and one third-party Starlette/AnyIO deprecation warning**, in 386.07 seconds. It ran from `VoxBridge/` with the repository environment and an explicit macOS 26 SDK:

```sh
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk ../.venv/bin/python -m pytest -q
```

A preceding native packaging check failed to compile with the default macOS 27 SDK. Selecting macOS 26 made the focused check and complete suite pass; no code repair was needed for that SDK issue.

Follow speech style regressions also passed in both directions, using 13 seconds of source audio per direction. Chinese→English received and played five PCM chunks with five caption changes; English→Chinese received and played three with three caption changes. During playback, the checks changed font size between 36 and 72 points, color and position every 250 ms. Assertions were enabled, scheduled frame spans matched all received PCM, and both runs drained completely.

## Actual App pipeline and history check

App 1.0.0 build 40 was installed and launched with the existing signing certificate, without new directory or audio permission prompts. A roughly 59-second Chrome playback of the Chinese source excerpt, 10:42–11:41, used native system-playback capture, Chinese→English interpretation, translation-only local audio and MacBook Air Speakers.

Input levels were nonzero, recognition and translation updated, and translated speech played. Finishing returned the App to service-ready state. Reading history retained 15 completed full-translation and correction entries after stopping. Settings remained Reading first with PingFang SC Semibold at 30 points, and the font-size shortcut bindings remained available in settings. After the check, the video was paused and returned to the beginning; the App remained ready without capture running.

This short App check validates the visible pipeline and retained history. It does not establish physical subtitle lead: no synchronized recording of screen and speaker output was made, and the separate subtitle overlay was not captured in the same screenshot as the console. The timing evidence above comes from the production native controller's ten-minute and three-minute replays.

## Scope and limits

These runs validate one excerpt in each direction on this Mac. They do not measure recognition or translation accuracy, semantic completeness against a human transcript, subjective reading comfort, or every possible speech rate and backlog. No physical recording of the screen or speaker output was made. The native drain waits for published PCM and actual playback, with a 60-second no-progress timeout and a 180-second hard limit; successful completion here does not guarantee processing and playing every utterance under an unlimited backlog.

Raw source media, generated PCM, transcripts and diagnostic reports remain local and are not included in this repository.

See [caption timing, history and limitations](../../VoxBridge/docs/READING-SUBTITLES.md) for the behavior outside these measured replays.
