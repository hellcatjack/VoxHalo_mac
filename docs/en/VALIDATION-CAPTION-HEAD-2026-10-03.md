# Caption drawing and English sentence-start validation

**English** | [简体中文](../zh-CN/VALIDATION-CAPTION-HEAD-2026-10-03.md)

This build 41 investigation addresses reports of weak/missing English first words and captions falling behind fast speech. It retains Qwen3-ASR 0.6B MLX INT8, HY-MT Q8_0, the existing Kokoro voices, synthesis settings, native scheduling and PCM bytes.

## Changes and observed cause

Sampling the running App found input-level callbacks repeatedly refreshing the entire console, including service-file checks and layout. Levels now update only the meter. Caption updates precede history-window updates; visible history merges bursts for 200 ms while retaining all records, selection and scroll position. A closed or minimized history window skips layout.

The console also truncated complete translation cards after three lines. It now wraps the whole card in its existing scroll container. This makes the tail available without changing card text, identity, font size or its playback lead. Very long console cards still require scrolling; this does not guarantee that the current spoken words are always inside the console viewport.

## Real fixed-excerpt replays

The current Chrome source was [LxpvBvDr21Q](https://www.youtube.com/watch?v=LxpvBvDr21Q), playing Chinese→English through system-playback capture and MacBook Air Speakers. It was paused at 10:34.3 before controlled replays. A locally saved, accurately cut 06:00–10:00 excerpt supplied exactly 240 seconds of source PCM. English→Chinese used the previously saved [xCUala5j7aQ, 22:00–25:00](https://www.youtube.com/watch?v=xCUala5j7aQ&t=1320s) excerpt.

Both replays used real recognition, translation, synthesis and native output. The harness installs the actual fixed-font/screen layout and a visible subtitle panel, runs the normal AppKit event loop, and records natural drawing callbacks and the final CoreText visible range. It does not force bitmap drawing for timing.

| Measurement | Chinese→English | English→Chinese |
| --- | ---: | ---: |
| Source duration | 240 s | 179.999 s |
| Runtime including startup, final drain and output analysis | 283.660 s | 193.765 s |
| PCM chunks received / played | 95 / 95 | 41 / 41 |
| Final native buffer | 0 | 0 |
| Caption state changes | 40 | 34 |
| Natural drawing callbacks | 39 | 32 |
| Unexpected past/missing caption coverage | 0 | 0 |
| Clipped visible caption cards | 0 | 0 |
| Negative observed RMS voice leads | 0 | 0 |
| Minimum observed RMS voice lead | 70.58 ms | 27.92 ms |
| Median observed RMS voice lead | 630.58 ms | 627.25 ms |
| Selection→drawing, maximum | 6.87 ms | 6.85 ms |
| Selection→drawing, P95 | 4.84 ms | 5.86 ms |
| Observed synthesis-speed status range | 1.26–1.575× | 1.20–1.50× |

Both complete sources returned to idle without errors, retained reading history and preserved every scheduled PCM frame count. Identical consecutive text can reuse already drawn pixels, so fewer draw callbacks than caption identities are valid; the observer records this separately without inventing a new drawing timestamp. Long pages use retained page anchors, and coverage permits valid physical pages and intentional upcoming-card transitions within the 600 ms lead window.

For the fast Chinese replay, an accepted and played chunk was compared with CPU re-synthesis at 1.20×, 1.44× and 1.50×. Its length matched the first 1.50× rendition, and two 1.50× correlations were 0.99363 and 0.99202, versus 0.33419 at 1.44× and 0.02064 at 1.20×. This supports actual 1.50× output rather than relying only on session status. The Chinese model contains unseeded random-source nodes, so re-synthesis is not byte-deterministic. This does not establish word-level intelligibility.

## English first words

An actual software mixer recording was compared with all 95 accepted English PCM chunks, including their first 300 ms. All 95 obtained reliable body alignment; no voiced 20 ms head window showed the defined severe energy loss: reference RMS above 0.001 and observed energy below 10% of the gain-normalized reference. Minimum head correlation was 0.96469. One chunk initially missed the correct correlation peak; exhaustive sample-level alignment recovered body correlation 0.99759 and head correlation 0.99940. The test analyzer now uses an FFT fallback for uncertain alignment. This was an analyzer limitation, not evidence of an audio cut. The replay pass checks caption coverage and draining; mixer confidence and sentence-start results were separately reviewed for all chunks.

A separate 14-second native probe preserved all 18 synthetic head markers across starvation resumes, queued sentences and 80 ms UI stalls. The speakers used 48 kHz with a 512-frame I/O quantum, about 10.67 ms. The render timestamp led wall time by 12.4–22.5 ms; actual scheduling margin was at least 32.5 ms. These observations do not support changing the production scheduler.

Four paired offline sentences included first-word phonemes in the model input; the retained PCM bytes matched the corresponding original interval exactly. This does not prove that the output pronounced every phoneme clearly. At 1.05×, Qwen recovered all four first words from both trimmed and untrimmed audio. At 1.575×, it recovered one from trimmed and four from untrimmed audio. Adding just 50 ms of digital silence restored two trimmed cases, demonstrating sensitivity to the recognition input boundary. This is not proof that a spoken word was deleted. A five-speed synthesis comparison identifies 1.35× as a listening candidate, with about 13–15% longer audio for the three tested sentences; no English speed change is made from energy measurements alone.

## Regression coverage and limits

UI tests feed 10,000 level callbacks without a full console/caption refresh. Actual CoreText drawing covers long English/Chinese text at 30 and 72 points, including complete final pages. The real console layout test verifies that a 250-word translation lays out every character and expands the scroll document beyond three lines. History tests cover burst coalescing, reopening, selection and scroll preservation. Mixer comparison tests cover 24→44.1/48 kHz resampling, gain, phase offsets, narrow correlation peaks, a deliberately lost 100 ms prefix and natural leading silence.

The full regression suite passed **1,398 tests, with 33 skipped**, in 393.29 seconds. An earlier run had one Carbon hotkey-registration failure while the installed App retained its last caption; the same check passed after quitting the App, followed by the full clean run. The candidate and installed build 41 passed strict signature verification using the existing certificate.

## Installed App and current Chrome playback

Build 41 was installed and launched using the same signing identity, without new directory or system-audio permission prompts. The current Chinese Chrome video then played from 10:34.3 to 13:42.1, about **187.77 seconds**, through the existing translation-only system capture and MacBook Air Speakers. Input levels, translations, reading cards and English speech continued; observed accelerated synthesis reached 1.575×. After pausing Chrome and stopping interpretation, the final sentence was translated and the App returned to ready with 33 monitor rows, zero queued/pending audio, no listeners and no session/TTS errors. Chrome was left paused and the source/target/output choices were preserved.

Together with the fixed replays, this supplies about **607.77 seconds of source audio** in this investigation. The installed-App check is a functional/UI smoke test; precise drawing and software-audio timings come from the instrumented replays above. This check does not claim to resolve subjective English first-word audibility.

## Limits

AppKit drawing completion is not physical display/compositor timing. The mixer tap is before the device/DAC and does not record the actual speaker, establish phonetic correctness, or resolve subjective first-word audibility. The replays do not compare ASR/translation completeness with a human transcript. They do not exercise an arbitrarily long, visible history window alongside the overlay. Page timing inside one long PCM chunk remains approximate, without word alignment. Test hooks are excluded from the shipping App; media, transcripts, PCM and raw reports remain local and are not committed.

See [caption behavior](../../VoxBridge/docs/READING-SUBTITLES.md), the [earlier controller-only measurements](VALIDATION-READING-2026-10-03.md), and [version history](../../CHANGELOG.en.md).
