# Changelog

**English** | [简体中文](CHANGELOG.md)

## Unreleased · Subtitle shortcuts and model management

- Add an eight-language model manager with actual storage locations, 18 model/supporting files, sizes, pinned download sources, checksums, missing/partial/damaged states and download progress.
- Restore selected files or all models, pause/resume downloads, preserve damaged-file backups, and regenerate the verified Chinese speed-control model. Inspection remains available during interpretation; writes exclude service startup and installation.
- See [model management](docs/en/MODEL-MANAGEMENT.md). The existing 1.8.0 download does not include this window.

- Control subtitles during interpretation with Control + Shift + Command and S, ↑, ↓, 9 or 0: show/hide, tap/hold movement, and top/bottom placement without taking presentation focus.
- Add eight-language shortcut settings with enable/disable, final-key customization, reset, conflict warnings and keyboard-layout-aware labels. Release global keys when interpretation stops.
- Save subtitle position and preserve the current spoken caption and non-audio pagination clock when hiding or moving. Audio capture, model settings and TTS scheduling are unchanged.
- See [subtitle shortcuts](docs/en/SUBTITLE-SHORTCUTS.md). These changes are not included in the existing 1.8.0 download.

## 1.8.0 · build 22 · 2026-09-15

- Add standalone DMG/ZIP distribution with a prebuilt relocatable Python/AI runtime and an eight-language native first-run installer. End users do not need developer tools.
- Download checksum-pinned models and speech components with progress, cancellation, resume, retry and explicit corruption repair that preserves backups. Check the actual installed runtime before enabling interpretation.
- Store shared assets and separate runtime versions under the user's Application Support folder. Model maintenance excludes active interpretation; existing source installations remain supported.
- Add repeatable packaging and GitHub Actions release publication, with SHA256SUMS and bilingual graphical installation guides. This release uses ad-hoc signing and has no Developer ID notarization.
- Handle eSpeak’s native data-path length limit with a private short-path copy when needed; preserve dictionary bytes and verify actual phonemization during installation.
- Preserve the verified models, prompts, audio ownership, language directions, caption timing and speech-rate settings.

## 1.7.1 · build 21 · 2026-09-15

- Refine the native main window with a compact header/status area, equal input/output columns, source and translation side by side, and a right-aligned LAN QR code.
- Use system typography, appearance-aware colors and subtle grouping. Auxiliary actions use system icons with localized tooltips and accessibility names. Initial height fits the content; additional window height goes to the transcript area.
- Preserve all eight interface languages, device selection, service actions and interpretation/speech behavior. Keep primary action titles intact in narrower windows.
- Validation: 96 locale/window-size/content layout combinations passed across light and dark appearances; the full suite passed 1,163 tests, with 32 skipped for optional environment requirements. Verified local installation, signature and saved settings; no audio endurance run was started for this UI change.

## 1.7.0 · build 20 · 2026-09-15

- Add eight offline interface languages to the App, menus, subtitle settings, monitor, listener and optional sign-in pages. Follow system/browser preferences by default and remember manual choices.
- Keep interface selection independent of audio devices and recognition/translation direction; switch during a session without restarting capture/playback or rewriting source/translated content.
- Bundle localized permission descriptions, add native/browser switching regressions, and accommodate longer text and mobile layouts. See [interface languages](docs/en/INTERFACE-LANGUAGES.md).

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
