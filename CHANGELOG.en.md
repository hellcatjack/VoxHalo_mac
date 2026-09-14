# Changelog

**English** | [简体中文](CHANGELOG.md)

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
