# Changelog

**English** | [简体中文](CHANGELOG.md)

## 2026-09-15 · Chinese speech-rate ceiling

- Expand automatic Chinese speech to the user-selected 1.10–1.30 range, with 1.10, 1.18, 1.26 and 1.30 steps. Retain existing backlog thresholds and whole-sentence synthesis.
- Preserve other-language rates and subtitle synchronization; compatible with App 1.6.1 build 19. Earlier 1.10–1.20 replay measurements remain historical validation.

## 2026-09-15 · English endpoints and Chinese speech rate

- Let English terminal periods enter final recognition at a confirmed VAD endpoint without the extra unchanged-text fallback wait. Preserve abbreviation/initial/ellipsis handling, final recognition and speech-revision checks.
- Limit automatic Chinese synthesis to 1.10–1.20, with intermediate 1.14 and 1.18 steps. Preserve whole-sentence synthesis, already-prepared audio and other-language rates.
- Two 180-second replays of identical English audio reduced translation-to-PCM P90 from 5.79 to 4.27 seconds; median latency did not improve and some confirmation waits remain. See the [validation report](docs/en/VALIDATION-LATENCY-2026-09-15.md). This service update works with App 1.6.1 build 19.

## 2026-09-15 · English quotation speech fix

- Keep a short quotation and its introduction in one synthesis when they fit the existing 18-word chunk budget, avoiding unnecessary comma, semicolon and colon cuts around quoted phrases.
- Distinguish straight/curly quotes, contractions, leading elisions and common plural possessives inside quotations. Preserve sentence stops, original caption text, long-quote limits and whole-sentence Chinese synthesis.
- This service update works with App 1.6.1 (build 19). Models, voices, speed and stabilization timers are unchanged. After updating the code, end interpretation and restart services through the App.

## 1.6.1 · build 19 · 2026-09-14

- Bind confirmation to exact source revisions; revoke unshared speech on edits or decoder withdrawal, and lock a sentence only at its first shared PCM commit.
- Use actual English decoder agreement for early release, with more conservative handling of negation, numbers and proper-name hints; retain preparation and existing timer settings.
- Make the App translation area follow audible captions; keep published speech and later corrections separate in the monitor.
- Preserve complete Chinese synthesis, automatic speed, the eight-language catalog and independent native operation. See [speech consistency](docs/en/SPEECH-CONSISTENCY.md).

## 1.6.0 · build 18 · 2026-09-14

- Redesign the listener page for multilingual interpretation, remove church branding from the page and lock-screen metadata, and improve responsive caption layout while preserving playback behavior.

- Enable Chinese, English, Japanese, French, Spanish, Italian, Portuguese and Hindi across all 56 directed pairs.
- Share one catalog between native source/target menus, Python pair validation and passive monitoring. Reject invalid pairs and missing speech resources before capture.
- Add six Kokoro voice routes while sharing the existing multilingual ONNX model; add a pinned offline Japanese pronunciation frontend and dictionary.
- Preserve Chinese/English prompts and speech behavior. Add script-aware validation, sentence boundaries, combining-mark-safe joins and spoken-prefix recovery.
- See [validation and limitations](docs/en/EIGHT-LANGUAGES.md). Existing installations must rerun `./setup.sh` to install the Japanese dependency and dictionary.

## 1.5.2 · build 17 · 2026-09-14

- Phase 1 modularization: language catalog, request contracts, translation service and queue, text rules, and speech policy/output interfaces.
- Retains Chinese/English models, prompts, complete Chinese sentences, PCM/HLS publication, catch-up speed and playback-synchronized subtitles.
- Moves the browser template out of the business entry point; adds bilingual architecture documentation and a native long-audio replay harness.
- New service validation rejects unavailable languages and inconsistent directions while preserving configured legacy Chinese/English labels.

## Chinese name update · 2026-09-14

- Standardized the Chinese project name to “同声传译” across App titles, menu-bar and permission messages, bundle filenames, and bilingual documentation.
- Kept `org.pccs.voxbridge.console` as the application identifier so existing device and subtitle preferences remain accessible.

## Documentation update · 2026-09-14

- Added separate English `README.md` and Chinese `README.zh-CN.md` entry points.
- Added bilingual installation and model guides covering pinned versions, quantization, prompts, model licenses, verification, permissions, updates, migration, and troubleshooting.
- Distinguished the suggested M1 / 16 GB / macOS 14.2 trial configuration from the validated M4 / 24 GB / macOS 26 configuration.
- The App remains 1.5.1/build 16. This update changes documentation only.

## 1.5.1 · build 16 · 2026-09-14

- Published the complete native Mac console, local ASR/translation/TTS services, independent browser monitoring, and LAN listening.
- Added HY-MT output checks and short-template recovery; supplied matched church terms in source order.
- Translated late append-only additions separately and removed repeated supplement prefixes from following ASR rows to reduce duplicate speech.
- Preserved Qwen3-ASR 0.6B INT8, HY-MT Q8_0, complete-sentence Chinese speech, automatic catch-up speed, and playback-synchronized subtitles.
- Added installation for fresh checkouts, pinned asset manifests, SHA-256 validation, automatic Chinese speed-model repair, and local App builds.

The source baseline was VoxBridge `224c5be`, with the last behavior fix at `920948e`. Publication packaging did not change recognition, translation, speech playback, or subtitle algorithms. See the [translation validation](VoxBridge/docs/MACOS-TRANSLATION-INTEGRITY.md) and [publication checks](docs/PUBLICATION.md), both in Chinese.

## 1.5.0

Added translation-only system playback capture through native Core Audio taps without a virtual sound card; improved device-disconnect handling and startup recovery.

## 1.4.x

Added configurable native subtitles, corrected Dock-area placement and playback synchronization, fixed fractional Chinese speech speed, and made Chinese synthesis prefer complete sentences.

## 1.3.x and earlier

Added Chinese/English directions, native input/output selection, independent service management, chunked PCM playback, and low-backlog scheduling. Historical version-specific records remain in `VoxBridge/docs/MACOS-*.md` in Chinese.

The original repository's `v1.0.0` was a remote subtitle client. It remains available for historical reference and is distinct from the current complete local system.
