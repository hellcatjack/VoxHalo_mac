# English endpoint latency and Chinese speech rate

**English** | [简体中文](../zh-CN/VALIDATION-LATENCY-2026-09-15.md)

Two sequential native replays used the same 180 seconds of existing local English audio on this MacBook Air. Baseline: `8910b1c`. The candidate includes the English-period endpoint fix and the user-selected Chinese automatic speed range. Qwen3-ASR 0.6B MLX INT8, HY-MT Q8_0, Kokoro `zm_029`, two TTS CPU threads, system-default output and the native playback implementation were identical. Input was streamed in real time through the production capture interface; file input replaced system capture.

Both file replays used empty ASR context terms. The user's saved App context terms were preserved.

## Cause and change

An English terminal period was omitted from the punctuation branch that lets an already-confirmed VAD endpoint enter final recognition. It fell through to another text-idle check, with a minimum 1.2-second text-stability age and a 20-character minimum, or waited for forced silence. If speech resumed first, the next seal could be the 12-second segment boundary. Translation and even prepared audio could already exist during this wait.

The fix recognizes terminal periods while retaining conservative handling of abbreviations, initials and ellipses, including wrapped abbreviations. VAD still requires the configured 800 ms silence. Final recognition still precedes sealing. No release-confirmation checks or 3-second/1-second stability timers were shortened.

Chinese automatic synthesis now uses absolute Kokoro speeds of 1.10, 1.14, 1.18 and 1.20, compressing the previous catch-up range. Prepared audio retains its selected speed. English, other-language and explicitly fixed rates keep their prior behavior.

## Measurements

| Measurement | Baseline | Candidate |
| --- | ---: | ---: |
| Input audio | 180 s | 180 s |
| Runtime including startup and final drain | 192.05 s | 193.89 s |
| Published sentence groups / PCM chunks | 25 / 27 | 28 / 29 |
| Translation ready → first PCM, median | 1.53 s | 1.74 s |
| Translation ready → first PCM, P90 | 5.79 s | 4.27 s |
| Translation ready → first PCM, maximum | 8.27 s | 8.37 s |
| Confirmation/order wait after translation, P90 | 5.79 s | 4.27 s |
| Release permission → first PCM, P90 | 1.66 s | 2.26 s |
| PCM publication → native scheduling, P90 | 0.078 s | 0.095 s |
| Empty-queue gaps longer than 2 s | 7 | 8 |
| Total empty-queue time between chunks | 66.41 s | 51.35 s |
| Maximum empty-queue gap | 18.26 s | 11.95 s |
| Generated audio including sentence pauses | 113.68 s | 131.15 s |
| Deferred VAD endpoint evaluations | 54 | 0 |
| Sampled active Chinese speeds | 1.05, 1.26 | 1.10, 1.14, 1.18 |

Translation-ready and PCM times come from matching source-order/revision trace events. Release-to-PCM includes synthesis and publication work; it is not a pure inference measurement. Empty-queue gaps come from native scheduled PCM frame positions and exclude pauses already inside the audio. They can also reflect pauses in the source. Quantiles cannot be added across columns.

The P90 translation-to-PCM wait improved about 26%, while the median and maximum did not improve. Slower Chinese speech also filled more of the timeline, so the reduction in total queue gaps must not be attributed entirely to endpointing. This is a combined single-pair comparison, not an isolated benchmark of each change or a claim that all long pauses disappeared.

## Consistency and limits

Both runs finished the input, played and drained their audio, and returned idle without service/playback errors. PCM sequences were continuous; published speech snapshots remained immutable; every speech group matched its PCM text and revision; sampled captions entered during matching audio. No mismatches were observed.

Concatenated ASR outputs each contained 417 normalized word/number tokens, with three differing spans. This checks broad output agreement, not accuracy against a human transcript. Earlier endpoints change sentence grouping and can change wording.

Regressions cover early English-period finalization with final redecoding, abbreviation protection, Chinese speed limits in both synthesis paths, prepared-audio reuse and explicit fixed rates. Chinese whole-sentence synthesis and the earlier quotation fix remain covered. An App rebuild is unnecessary; this is compatible with App 1.6.1 build 19.

The full Python suite completed with **1,069 passed, 6 skipped and 1 warning**. The skips concern optional ONNX, browser and ffprobe checks; the warning is an existing Starlette/AnyIO deprecation.

Continuous speech, unresolved revisions, incomplete clauses and final recognition can still cause multi-second waits. A completed translation is not itself permission to speak. Source recordings, transcripts, diagnostic logs and PCM are retained locally and are not published.
