# 1.6.1 validation record

**English** | [简体中文](../zh-CN/VALIDATION-1.6.1.md)

Date: 2026-09-14. Hardware: Apple M4, 24 GB unified memory, macOS 26.6.2. App: 1.6.1 (build 19). See [speech and caption consistency](SPEECH-CONSISTENCY.md) for the behavior contract.

## Method

`NativeFileReplayChecks.swift` feeds 600 seconds of mono 16 kHz PCM per direction at real-time pace through the actual local Qwen3-ASR 0.6B MLX INT8, HY-MT1.5-1.8B Q8_0, Kokoro, native player and caption clock, using the system default output. English uses minutes 4–14 of an existing local narration download; Chinese uses minutes 10–20 of an existing local talk download.

This validates services and native playback with file input replacing system capture. It does not independently revalidate macOS recording permission or browser source isolation. Models and voices remain unchanged: `zm_029` for Chinese and `am_michael` for English, with automatic speed enabled.

## Long-run results

| Measurement | English→Chinese | Chinese→English |
| --- | ---: | ---: |
| Input audio | 600 s | 600 s |
| Total runtime, including startup and drain | 620.94 s | 609.29 s |
| Published sentence revisions | 96 | 80 |
| PCM chunks / nonempty captions matching audio | 100 / 100 | 120 / 120 |
| Gapless joins within a sentence revision | 4 / 4 | 40 / 40 |
| Gapless joins across all adjacent chunks | 55 / 99 | 77 / 119 |
| Total synthesized audio | 405.31 s | 382.78 s |
| Sampled peak playback backlog | 14.20 s | 6.70 s |
| Service or playback errors | 0 | 0 |
| Published record / PCM text mismatches | 0 | 0 |

Both directions played in order and drained their final tails. The last 100 ms polling sample for Chinese→English retained 2.67 ms; native `stop(drain: true)` subsequently confirmed drain and returned idle. That sampling gap must not be misreported as a lost audio tail.

English→Chinese published 8 sentences through streaming confirmation, including 3 using the low-buffer shortcut; 83 were sealed by final recognition and 5 completed during final drain. One confirmation was revoked. Chinese→English had 32 streaming releases, 47 final seals and 1 final-drain release.

All published speech records remained immutable. One actual correction after publication occurred in Chinese→English: the original speech record remained, the latest full translation was stored separately, and the playback caption was neither overwritten nor followed by a duplicate rendition of the sentence.

## Regressions and UI

- Full Python suite: **1013 passed, 6 skipped**, 171.19 seconds. Skips comprise one optional ONNX conversion check, three Playwright browser checks, and two checks requiring additional `ffprobe`. One Starlette dependency deprecation warning remains.
- New deterministic regressions cover queued revisions, raw ASR withdrawal, negation/numbers, blocked encoding, reconfirmation timing, same-revision retry, final tails and compatibility listener notifications.
- Swift caption checks passed: captions hold during queueing, pause and starvation, then advance at the matching audio boundary.
- Browser verification confirmed the monitor loads, later corrections are collapsed by default, and expanding a correction preserves the published speech record. No browser script errors were observed.
- Native App compilation and strict signature verification passed.

## Interpretation

This run checks audio ordering, revision consistency, caption entry times, joins and final drain. It is not a human sentence-by-sentence translation quality evaluation. Semantic accuracy still depends on ASR and translation, and later context can change the best wording.

Existing 3-second normal and 1-second eligible low-buffer windows were not increased. Translation and preparation still overlap confirmation. English risk hints can delay individual sentences relative to previous behavior. This integration run is not an isolated-load latency A/B benchmark and does not establish lower overall latency.

Source audio, sentence transcripts, logs and diagnostic JSON remain local and are not uploaded to the repository.
