# Eight-language implementation and validation

**English** | [简体中文](../zh-CN/EIGHT-LANGUAGES.md) · [Project home](../../README.md)

2026-09-14 · App 1.6.0 / build 18 · MacBook Air M4 / 24 GB. Baseline: `7029cc1` (phase 1).

## Enabled languages

Chinese (`zh`), English (`en`), Japanese (`ja`), French (`fr`), Spanish (`es`), Italian (`it`), Portuguese (`pt`) and Hindi (`hi`). Every source can target any of the other seven: 56 directed pairs. Portuguese synthesis uses Brazilian Portuguese. These eight are the implemented intersection of recognition, translation and speech; upstream support for additional languages does not enable them in this App.

Select **识别** (source) and **译音** (target) before capture. The App prevents identical pairs, retains existing zh2en/en2zh preferences and validates the service acknowledgement. ASR is forced to the selected source. Translation, TTS and passive monitor labels use the same pair. The monitor neither selects a language nor owns capture/playback.

Chinese and English retain their verified prompts, voices, whole-Chinese-sentence synthesis and playback scheduling. Other pairs use HY-MT's official short templates. New sentence policies support Japanese punctuation, Hindi danda/double danda, common Latin abbreviations, decimals and ellipses. Unicode revision handling preserves combining marks, mixed-script names and late additions after already spoken prefixes.

## Automated verification

- Baseline: 876 tests passed, 9 skipped.
- Final suite: **989 passed, 9 skipped**, one third-party deprecation warning. Skips: one optional ONNX repair dependency, three Playwright cases, five FFmpeg/ffprobe test-PATH cases. Runtime FFmpeg is installed; skips are not passes.
- All 56 native start handshakes check ASR/source/target consistency. Invalid and identical pairs are rejected. Missing target pronunciation resources fail before ASR starts. New-source sentences bypass the English fragment hold.
- Swift checks cover all 56 pairs, acknowledgement mismatches and old preference restoration. The full App compiles; 1.6.0/build 18 metadata, signature and the bundled catalog are verified.
- Independent review found and resolved Unicode joins, Japanese prolonged-sound marks, Hindi terminators, ellipses, output-script checks and English-only fragment rules. Existing mixed Chinese/English spoken-prefix regression passes.

## Actual local models

The verified Qwen3-ASR 0.6B MLX INT8, HY-MT1.5-1.8B Q8_0/mac-verified and Kokoro settings are unchanged. Tests used the real models rather than API mocks.

**Translation:** one semantically equivalent ordinary sentence per source was translated into every other target. All **56** requests produced nonempty text. Serial translation median was **0.706 s**, maximum **1.480 s**. These short-text measurements exclude capture, stabilization, synthesis and device latency; they are not a general translation-quality benchmark.

**Speech:** actual offline synthesis succeeded for all eight targets with network connections disabled in the test process. All output was 24 kHz mono PCM. Exactly two ONNX model instances were cached: one Chinese model and one shared seven-language model. Japanese used `pyopenjtalk==0.4.1` and the checksum-pinned local dictionary. No runtime download was needed.

**Native streaming and playback:** short synthesized source fixtures were resampled to 16 kHz, framed at 100 ms and sent at the real clock rate through production `NativeSession` and `NativeSpeechPlayer`, using system default output. Eight sessions covered each source and each target once:

| Direction | Speech chunks | Outcome |
|---|---:|---|
| Chinese → English | 2 | Completed and drained |
| English → Japanese | 1 | Completed and drained |
| Japanese → French | 2 | Completed and drained |
| French → Spanish | 2 | Completed and drained |
| Spanish → Italian | 2 | Completed and drained |
| Italian → Portuguese | 2 | Completed and drained |
| Portuguese → Hindi | 2 | Completed and drained |
| Hindi → Chinese | 2 | Completed and drained |

Total elapsed time was about 113 seconds. Input files contained two copies of each short utterance with silence. Revisions/deduplication can combine repeated content; the chunk count is not a word-accuracy score. File replay bypasses microphone/system-audio capture, so these sessions do not revalidate device permission handling.

Installed-App check: after macOS refreshed the updated App’s system-audio permission, the native **system audio / translation only** input captured a local English sample, recognized “Welcome to our meeting”, translated it to “欢迎参加我们的会议。”, and completed native playback through system default output. Ending from the App returned to ready with empty synthesis queues and no TTS error. No browser controlled capture or playback.

## Long Chinese/English replay

Both tests use 600 seconds of real source audio at the actual clock rate: the Chinese sermon’s 10:00–20:00 interval, and a Genesis 2/3/4 English concatenation. Production native PCM playback runs to system default output, followed by normal drain. The checks cover complete chunk groups, monotonic sequence/source order, matching caption/playback timing and playback of every received audio chunk.

| Direction | Input | Elapsed including drain | Speech chunks | Gapless joins within source groups | Result |
|---|---:|---:|---:|---:|---|
| Chinese → English | 600 s | 609.17 s | 122 | 41/41 | Passed |
| English → Chinese | 600 s | 612.01 s | 100 | 6/7 | Completed; see observation below |

The English→Chinese run had one 0.863 s wait within a source group, after a complete Chinese sentence; the following audio was created after the preceding audio ended. Its final 100 ms diagnostic sample showed 99 of 100 chunks played and 2.667 ms remaining. Normal stop then returned `idle` without an error. Completion of that last tail is established by the native drain contract (the actual playback callback must advance to the server tail before success), rather than by a sampled zero-buffer snapshot. A focused native-player check passed for playback completion, restart fencing and refusal to drain an incomplete sentence. Raw measurements are preserved; audio scheduling was not changed to address this observer race.

A wait between different completed utterances can be valid while the next translation or audio is being prepared. These measurements distinguish that from adding silence between audio chunks already available to play.

## Quality limits and upgrade

All 56 pairs are implemented, but linguistic parity is not established. The six added languages have short synthetic-fixture validation, not ten-minute native-speaker evaluations across accents/noise. Script checks cannot distinguish French from Spanish or Portuguese reliably. Japanese Han text can be ambiguous with Chinese, proper names can stay in their original script, and the ASR window may revise punctuation.

A real Hindi→Chinese sample rendered “welcome to our meeting” as “welcome to our meeting room”; integration success does not establish perfect semantic fidelity. Short samples also show tense and phrasing variation across translations. New-language speech-duration estimates are provisional and voices have not undergone comparative human listening tests. French currently uses the available female `ff_siwis` voice; Portuguese uses `pt-br`. Review the [model/voice guide](MODELS.md) before choosing a deployment.

Existing users should stop interpretation and rerun `./setup.sh` after updating. This installs the new Japanese dependency/dictionary and rebuilds the App. A source-only pull is insufficient. About 4.58 GB of pinned assets are downloaded in a fresh installation; the existing 20 GB storage allowance and 16 GB evaluation / 24 GB validated memory guidance remain. Models, audio fixtures, logs and credentials are not committed.
