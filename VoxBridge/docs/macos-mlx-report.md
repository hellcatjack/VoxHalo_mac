# macOS MLX ASR adapter report

Date: 2026-09-12

## Runtime contract

`voxbridge.asr.mlx_backend.MLXQwenASR` adapts the locally installed
`mlx-qwen3-asr==0.4.0` session to VoxBridge's existing Qwen streaming
interface. It keeps the original `audio_accum`, `buffer`, `unfixed`, `text`,
`language`, and `chunk_id` state fields so the existing sentence revision,
segment finalization, translation, and TTS code remains in use.

The adapter performs a repeated full-window decode after each configured
audio interval (2 seconds in the macOS launcher), then decodes any remaining
tail on Stop or endpoint finalization. The same state may continue after a
provisional endpoint finalization, as expected by the existing VoxBridge VAD
flow. Audio state is capped at 45 seconds. The macOS launcher rotates empty
states at 12 seconds with 0.32 seconds of overlap. If pressure coalescing would
cross that boundary, the consumer splits the batch at the remaining sample
count, rotates, and processes the deferred suffix in the new state. This keeps
the empty MLX window at or below 12.32 seconds.

The native mlx-qwen3-asr incremental cache is deliberately unused because the
locally evaluated cached path had worse recognition quality. `chunk_id`
advances only when a real full-window decode runs, so the existing Qwen
observation policy does not mistake buffered calls for decoder evidence.

## MLX configuration and scheduling

- Model: local `models/qwen3-asr-0.6b` only. A remote model ID or incomplete
  directory is rejected before runtime construction, preventing a download
  fallback.
- Activations: MLX FP16.
- Default weights: affine INT8, `group_size=64`; FP16 weights remain available
  through `--mlx-precision fp16`.
- Decode output cap: 256 tokens in the macOS launcher.
- Runtime ownership: model loading, quantization, warmup, and every transcription
  execute on one `qwen-metal` executor thread.
- GPU admission: the adapter exposes one `threading.Lock`. MLX inference and
  the configured translator share that lock in CLI startup, preventing Metal
  ASR and local HY-MT work from overlapping.

All MLX imports are inside the MLX loader. Selecting `--backend mlx` does not
import Torch, vLLM, or `qwen_asr`; the existing Linux backends retain their
lazy backend-specific imports and defaults.

## Continuous PCM finding

The first complete macOS path run successfully produced ASR, HY-MT
translation, Kokoro speech, and shared HLS, but the mixed-language fixture
recognized `always always` as `OS`. Direct one-shot comparisons first ruled
out language selection: forced `Chinese` and automatic language detection
produced identical output:

```text
这是第一种，第二种叫呃与always always什么意思啊？
```

The result remained identical after the same PCM16 round trip and trailing
silence used by the end-to-end client. A duration sweep showed the model
output progressing from `O S` at 4.0 seconds to `always` at 4.1 seconds and
`always always` at 4.4 seconds. CPU reconstruction of the WebSocket energy
gate then found that it admitted 0.0-0.2 seconds, skipped 0.2-0.8 seconds, and
restored only 0.4-0.8 seconds from the 0.4-second speech pre-roll. The MLX
window therefore had a 0.2-0.4-second hole.

A controlled GPU A/B used one loaded runtime and the first 81,600 samples
(5.1 seconds) from `artifacts/macos/mixed-source.wav`. This slice is
sample-identical to the official mixed fixture. The intact window had SHA-256
`557775a2dcced6815355ca4199e00dde05a773f3a712404cd0decb54605c0a35` and
decoded as:

```text
这是第一种，第二种叫呃与always always什么意思啊？
```

Deleting only samples 3,200-6,400 (0.2-0.4 seconds) produced SHA-256
`14ed774842ff74c121e3eb337fde192620c070773f710da141cbbda88c23b628` and
reproduced the exact production substitution:

```text
这是第一种，第二种叫呃与OS，OS什么意思啊？
```

This isolates discontinuous PCM as the cause rather than language selection
or final-tail redecoding. The structured evidence is saved in
`artifacts/macos/mlx-pcm-gap-ab.json`.

For MLX, VoxBridge now sends every received binary PCM packet to the adapter,
including finite low-energy packets before and during speech. Browser clients
represent long silence with compact control spans, so this does not require
transporting long runs of zero-filled binary audio. The adapter gates actual
inference at the configured 2-second interval, while VAD endpointing and the
bounded empty-hypothesis rotation cap silent sessions. WebSocket regressions
use fake runtimes that echo context or emit an arbitrary `嗯。` for ten seconds
of zeros; the server filters both kinds of no-speech hypothesis and publishes
no partial or committed caption. The filter depends on absent VAD speech
evidence and an empty prior snapshot rather than recognized words. Speech
evidence is segment-scoped and may come from the energy detector or enabled
Silero rescue; it resets on every rotation. A regression uses -48 dBFS quiet
speech that the energy detector misses but Silero confirms, followed by
silence and a segment rotation. VoxBridge preserves the spoken sentence and
still rejects an arbitrary hypothesis from the next all-zero segment.

## Automated verification

Focused adapter suite:

```text
../.venv/bin/python -m pytest tests/test_mlx_backend.py -q
19 passed, 1 dependency deprecation warning in 0.37s
```

Focused adapter, registry, decode-gate, parser, and WebSocket regressions:

```text
../.venv/bin/python -m pytest -q tests/test_mlx_backend.py \
  tests/test_asr_engines.py \
  tests/test_demo_streaming_ws_utils.py::test_should_skip_stream_decode_for_clean_silence_without_pending_text \
  tests/test_demo_streaming_ws_utils.py::test_should_skip_stream_decode_when_pure_silence_has_no_speech_phase_yet \
  tests/test_demo_streaming_ws_utils.py::test_should_skip_stream_decode_even_when_pending_text_exists \
  tests/test_demo_streaming_ws_utils.py::test_should_not_skip_stream_decode_when_snr_is_high \
  tests/test_demo_streaming_ws_utils.py::test_should_skip_stream_decode_for_in_speech_trailing_silence \
  tests/test_demo_streaming_ws_utils.py::test_should_not_skip_stream_decode_for_in_speech_tiny_silence \
  tests/test_demo_streaming_ws_utils.py::test_parse_args_accepts_force_language_and_max_new_tokens \
  tests/test_demo_streaming_ws_protocol.py::test_ws_ready_partial_final_flow \
  tests/test_demo_streaming_ws_protocol.py::test_ws_replays_skipped_audio_once_when_decode_resumes \
  tests/test_demo_streaming_ws_protocol.py::test_ws_context_long_silence_never_decodes_or_publishes_hotwords \
  tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_rotates_empty_audio_windows_and_recovers_with_later_speech \
  tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_rotates_empty_client_silence_spans_without_asr_decode
38 passed, 1 dependency deprecation warning in 1.23s
```

The adapter tests cover independent session state, lossless PCM accumulation,
decode interval gating, final tail behavior, continued use after provisional
finalization, context and language forwarding, result-list compatibility,
invalid and oversized input, local-only model loading, exact INT8 group 64 /
FP16 configuration, single-thread ownership, shared-lock exposure, registry
capability, lazy CLI loading, pre-speech PCM continuity, Stop-tail behavior,
bounded empty-window rotation, later-speech recovery, and context or arbitrary
model-output suppression during a ten-second silent WebSocket session. They
also cover quiet speech confirmed only by Silero and reset of that evidence at
the next segment.

## Integration status

The final frozen service run retained `always always`, `Monday`, `Today`,
`The day after tomorrow`, and `frequently`. The raw-PCM tail contains no
extra no-speech `嗯。` after the silence guard. The 23.84-second input reached
its final event at25.55seconds, and the shared HLS decoded to31.02seconds
including carrier silence. Both listener lease checks and last-listener
cleanup passed. Evidence: `artifacts/macos/e2e-mixed/report.json` and
`after.json`.

The previous run with the isolated tail output is retained separately in
`artifacts/macos/e2e-mixed-before-silence-guard/`. Full deployment, sermon,
reverse translation and actual browser evidence are in
`docs/MACOS-VERIFICATION.md`.
