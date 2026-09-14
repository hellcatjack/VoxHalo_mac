# Phase 1 refactor validation

English | [简体中文](../zh-CN/PHASE1-VALIDATION.md)

2026-09-14 · App 1.5.2 / build 17 · MacBook Air M4 / 24 GB. Baseline: `187ef43`. This phase extracts modules while retaining existing Chinese/English behavior.

## Automated checks

- Baseline full suite: 866 passed, 9 skipped. Final code: 876 passed, 9 skipped.
- Skips: one missing ONNX repair dependency, three missing Playwright cases, and five missing FFmpeg/ffprobe test-PATH cases. Runtime FFmpeg is available; skipped tests are not counted as passes.
- 36 moved functions, classes or constants have identical syntax trees; eight prompt variants and five text-boundary fixtures match the baseline output.
- Core translation modules import in a process without FastAPI or the business CLI.
- Added pair validation, direction consistency, error, cancellation, independent queue, configured-label compatibility and whole-Chinese-sentence tests.
- Native App and replay harness build successfully. App signature and 1.5.2/build 17 metadata checks pass.
- Independent review findings concerning pair validation and legacy labels were fixed and re-reviewed.

## Native real-time replay

Mono PCM16 at 16 kHz is fed to production `NativeSession` in 100 ms frames at the actual clock rate. Production `NativeSpeechPlayer` plays to system default output, without a browser. Normal stop/drain follows the end of input.

Chinese input is sermon `q5tBWsDc8gI` from 10:00–20:00. English input is the first 600 seconds of concatenated Genesis 2/3/4 audio. Directions run sequentially, totaling 20 minutes of input. Models remain Qwen3-ASR 0.6B MLX INT8, HY-MT Q8_0 and Kokoro `am_michael` / `zm_029`.

| Metric | Chinese → English | English → Chinese |
|---|---:|---:|
| Audio input (s) | 600 | 600 |
| Elapsed including start and drain (s) | 608.42 | 612.59 |
| PCM speech chunks | 123 | 97 |
| Utterance/revision groups | 82 | 85 |
| Gapless joins within source groups | 41 | 11 |
| Waits for next sentence within source groups | 0 | 1 |
| Sampled peak backlog (s) | 7.513 | 10.807 |

Both directions consumed all input, reported no session errors and returned to idle. Every received PCM block completed playback and final buffering was zero. Sequence numbers were contiguous, source order did not regress and chunk groups were complete. Each nonempty subtitle transition occurred inside its corresponding audio frame interval. Whole-sentence Chinese and existing English chunking policies were retained.

All 41 joins within Chinese-to-English source groups were adjacent. For English-to-Chinese, 11 of 12 such joins were adjacent; one waited about 1.387 seconds between two complete sentences. The next audio was created approximately 1.31 seconds after the preceding estimated playback end and scheduled about 89 ms later. This was a synthesis-supply wait, with no observed HLS silence-carrier wait. Inter-utterance waits for source speech, ASR, translation or synthesis can still occur; this is not a claim of uninterrupted speech throughout. Backlog is sampled every ten seconds, not an exact peak. Observed synthesis speeds were 1.05 and 1.26.

## Scope and reproduction

File input bypasses recording hardware. This run does not revalidate system-audio permissions, microphone hardware, subjective headset quality or phone HLS playback. It validates actual models through native playback and subtitles, not human-scored recognition/translation quality or a performance improvement. Browser-template and playback-timeline algorithms are unchanged.

Audio, PCM, logs and detailed local reports stay in ignored `VoxBridge/artifacts/refactor-phase1/` and are not published. The harness is `VoxBridge/tests/macos/NativeFileReplayChecks.swift`; compile with `NATIVE_PLAYBACK_TESTING` and production Swift sources, excluding production `main.swift` and the icon generator. Arguments are service root, at least 600 seconds of PCM, direction, report path and output UID (`default`). Start local services with `./macos.sh start` first.

No models, quantization or prompts were replaced, and no additional languages were enabled. See [architecture boundaries](ARCHITECTURE.md) for remaining work.
