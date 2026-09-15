# Interpretation modules and boundaries

**English** | [简体中文](../zh-CN/ARCHITECTURE.md) · [Project home](../../README.md)

App 1.6.0 builds on the phase 1 module extraction and enables eight languages / 56 directed pairs. The verified models, Chinese/English prompts and speech chunking, stabilization and atomic audio commit algorithms are retained.

## Responsibilities

| Module | Responsibility |
|---|---|
| `voxbridge/language_catalog.json` + `languages.py` | One catalog bundled by both Python and Swift; immutable profiles and pairs; rejects unavailable languages and identical source/target pairs |
| `interpretation/contracts.py` | Immutable translation requests, per-session bounded queue and latest-revision index |
| `interpretation/translation_queue.py` | Translation concurrency limits, waiting and cancellation cleanup |
| `interpretation/transcript.py` | Source-text policy interface; retained Chinese/English rules, sentence/abbreviation/Unicode rules for added sources |
| `streaming/sentence_rules.py` | Verified sentence, clause, abbreviation and incomplete-phrase boundaries |
| `translation/prompts.py` | Verified prompts and domain policy, independent of network requests |
| `translation/backends.py` | Local Transformers and OpenAI-compatible HTTP clients; this Mac uses HTTP to local HY-MT |
| `translation/service.py` | Async translation, language checks, retries, errors and diagnostics, without FastAPI |
| `tts/policy.py` | Target-language chunking, phonemizer label and initial speech-duration estimate |
| `tts/output.py` | Explicit preparation, publication, status and source-generation port |
| `tts/hls.py` | Existing synthesis scheduling and atomic PCM/HLS publication, retaining continuous-playback ordering |
| `web/pages.py` | Legacy browser template moved out of the business entry point |

Core modules can be imported without constructing a web application or opening a browser. Existing CLI imports remain compatible while tools and tests migrate.

## Sentence lifecycle

The native App submits audio. ASR revises the source; the text policy proposes boundaries; the existing commit state machine owns sentence identities and revisions. Translation requests carry the sentence ID, revision, source text, ASR language, sequence, session generation and language pair. Stale-result checks remain before and after inference.

Completed translations may be synthesized ahead of release. Only the current revision approved by the stability buffer can be published. The shared publisher retains the same commit point for native PCM and HLS. Subtitles follow actual playback, playback-buffer feedback continues to influence release timing, and browser monitoring reads passive snapshots.

## Reusing the translation service

This example calls an already running local HY-MT server. It translates text only and does not own ASR, speech or subtitle state.

```python
from voxbridge.interpretation.contracts import TranslationRequest
from voxbridge.translation.backends import OpenAIAPITranslator
from voxbridge.translation.service import TranslationService

backend = OpenAIAPITranslator(
    "http://127.0.0.1:8876", "hy-mt",
    max_new_tokens=256, sampling_profile="mac-verified",
)
service = TranslationService(backend)
request = TranslationRequest(
    sentence_id="example-1", revision=1, source_text="Welcome to PCCS.",
    language="English", seq=1, generation=1,
    source_language="English", target_language="Chinese", direction="en2zh",
)
# Run inside an async function:
translated_text = await service.translate(request)
```

Requests use model language strings. `TranslationService` validates enabled language pairs and direction consistency before inference, rejecting unavailable languages. Session creation can also call `translation_pair(source, target)` to validate configuration early. Explicitly configured legacy Chinese/English labels retain their original prompt wording. Missing directions retain the default at the compatibility boundary; unknown explicit directions are rejected before session mutation. The selected pair is authoritative for ASR, translation and TTS. `/api/languages` exposes the eight profiles and 56 allowed directions.

## Remaining boundaries

The native App reads the common JSON catalog and stores a canonical pair string, preserving old zh2en/en2zh preferences. Source and target menus exclude identical pairs; switching requires ending capture. The WebSocket revision state machine and speech publisher remain in their existing orchestration layer. The complete session has not yet become a standalone generic session class.

Adding a language requires its text and speech strategies, pronunciation/number/code-switching/boundary/output-language validation, and updates to capabilities and the native handshake. Chinese/English regexes and church terminology must not be applied blindly to other languages. Further publisher extraction must retain stale-revision checks, cancellation commit fences, replay protection and the continuous PCM timeline.

## Verification

From `VoxBridge/`, run `../.venv/bin/python -m pytest -q -rs`. Core tests invoke independent services; existing protocol, revision, speculative translation, TTS, playback and subtitle tests continue to protect externally visible behavior.

`tests/macos/NativeFileReplayChecks.swift` is a manual integration harness requiring the local model services. It feeds at least ten minutes of 16 kHz mono PCM16 in 100 ms frames through production `NativeSession` and `NativeSpeechPlayer`. File input bypasses the capture device, so this validates the model-to-playback path, not system-audio recording permissions. Audio fixtures, PCM and logs are not committed.

[Eight-language validation](EIGHT-LANGUAGES.md) · [Phase 1 validation results](PHASE1-VALIDATION.md)
