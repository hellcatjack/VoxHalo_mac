# Independent macOS migration review

Reviewed 2026-09-12 against source baseline `8b4fdaa`, the staged migration, and the macOS design and implementation plan. Review was read-only apart from this report. No models, services, browser sessions, or broad test suites were started or changed.

## Accepted findings

### [P2] Rotate an empty MLX window before reaching its hard bound

Location: `<workspace>/VoxBridge/voxbridge/asr/mlx_backend.py:227` (integration: `<workspace>/VoxBridge/voxbridge/cli/demo_streaming_ws.py:9784`).

The adapter rejects any window exceeding 45 seconds, but the existing segment policy only rotates at the configured 12-second hard cut when `has_pending_text` is true. Audible music/noise or an unrecognized passage can keep entering the adapter while producing empty hypotheses, so the first packet beyond 45 seconds raises from the audio consumer. The promised bounded operation must also cover empty hypotheses: rotate/reset an empty MLX state at the configured boundary before the next append can exceed the cap, preserving the desired overlap and keeping the same live session usable.

CPU-only reproduction used the real adapter with a fake runtime returning empty text, the real `SegmentPolicy(hard_cut_ms=12000)`, and 46 one-second nonzero NumPy frames. At second 46 the state retained 45 seconds, policy reason was `hard_cut` but `should_cut=False`, and `streaming_transcribe` raised `ValueError: audio exceeds the configured maximum bounded window`. No GPU runtime was imported.

### [P2] Do not reconstruct process argv by shell-splitting macOS ps output

Location: `<workspace>/VoxBridge/tools/macos_service.py:71`.

`ps -o command=` returns arguments joined by spaces without shell quoting. `shlex.split(actual) == command` therefore fails when the workspace path contains a space, even though `Popen` correctly launched the process using an argv list. This makes a correctly running translation sidecar appear unowned, prevents readiness from succeeding, and makes rollback/stop skip the child while deleting its ownership record. This conflicts with the documented whole-workspace relocation procedure and is a common macOS path shape. Use an argument-preserving process inspection mechanism or a process identity scheme that does not assume the printable command is shell-escaped; retain the protection against signaling unrelated processes.

A bounded CPU self-inspection command confirmed that this Mac's `ps` does not round-trip an argument containing spaces through `shlex.split`. The current `<workspace>` path contains no spaces, so this does not block the currently running deployment.

## Minor documentation point

The design document still specifies translation `top_p1`; the macOS launcher’s `mac-verified` profile, its regression test, and `docs/MACOS.md` agree on `top_p0.6` plus the other existing local settings. Align the design record with the verified configuration to avoid contradicting the exact-settings acceptance criterion. This is documentation drift, not a request to change the runtime settings.

## Review coverage and limits

- MLX: local-path validation, FP16 load plus INT8 group64 quantization, one executor owning model load/warmup/transcription, state isolation, decode interval, final tail, and shared translation admission lock are present and internally coherent. The new post-speech energy-gate exemption addresses the observed dropped-PCM issue for binary audio packets.
- Listener: links and QR are derived from the same request origin or validated override; QR generation is local, URL schemes/credentials/paths are constrained, and the main-page attribute is escaped. The explicit LAN and localhost limitations are documented.
- Runtime: absolute parent-workspace resources, pinned local llama.cpp arguments, offline Hugging Face environment, startup order, HTTP readiness, rollback, and guarded stop are implemented. The requirements lock and explicit setup path avoid requiring the Linux GPU stack for this Mac deployment.
- Native Silero: legacy and modern ONNX input/state paths are implemented; the supplied new tests exercise legacy state handling and NumPy observer operation. No additional concrete correctness finding was identified in the modern path by inspection.
- One validation distinction remains: `tools/macos_e2e.py` sends continuous binary PCM and does not exercise the browser `AudioActivityGate` / `audio_silence` transport. That control path intentionally omits quiet PCM and can retain a segment across a pause; browser verification should include pause/resume behavior. This is a coverage observation, not a separately confirmed defect.
- The coordinator owns the real mixed-language, sermon, reverse-direction, browser/audio, and complete regression acceptance runs. Their results were not independently rerun for this review; the regression log was still in progress when inspected.

No P0 or P1 issue was identified.

## Resolution (2026-09-12)

Both accepted P2 findings are resolved.

- The WebSocket consumer now splits pressure-coalesced audio at the remaining empty-MLX hard-cut samples and rotates the state at the configured 12-second boundary. It uses received-media duration as well as wall time, retains the configured 0.32-second overlap, keeps the adapter window at or below 12.32 seconds, emits no empty sentence or translation, and leaves the session usable when recognizable speech arrives later. Compact browser `audio_silence` spans advance the same bounded segment clock without entering ASR.
- The macOS service manager reads exact NUL-delimited process arguments with `KERN_PROCARGS2`. Ownership remains an exact argv comparison and fails closed when inspection is unavailable or any argument differs. The regression uses a real child whose model argument contains spaces and also verifies that a different recorded argument is not owned.
- The design record now matches the verified local translation profile at `temperature=0` and `top_p=0.6`.

The new regressions were first run against the prior implementation and failed in all three target cases: the exact argv API was absent, the spaced child was not recognized as owned, and a 64-second empty-hypothesis stream exceeded the adapter's 45-second cap. After the fixes, focused CPU-only verification passed:

```text
../.venv/bin/python -m pytest tests/test_macos_runtime.py -q
7 passed in 0.19s

../.venv/bin/python -m pytest tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_rotates_empty_audio_windows_and_recovers_with_later_speech tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_rotates_empty_client_silence_spans_without_asr_decode tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_split_remainder_does_not_coalesce_across_client_silence tests/test_demo_streaming_ws_protocol.py::test_ws_mid_speech_hard_cut_skips_blocking_segment_redecode tests/test_demo_streaming_ws_protocol.py::test_ws_hard_cut_before_vad_endpoint_keeps_mid_speech_tail_without_redecode tests/test_demo_streaming_ws_protocol.py::test_ws_session_context_survives_hard_cut_rotation -q
6 passed, 1 warning in 4.89s

../.venv/bin/python -m pytest tests/test_mlx_backend.py::test_mlx_bounded_window_is_not_given_gapped_pcm_by_decode_skip_gate tests/test_mlx_backend.py::test_mlx_window_retains_low_energy_pcm_after_speech_starts tests/test_mlx_backend.py::test_received_pre_speech_pcm_stays_in_mlx_window_and_stop_flushes_once tests/test_mlx_backend.py::test_mlx_long_silence_with_context_never_publishes_context_echo -q
4 passed, 1 warning in 0.21s
```

The warnings are Starlette's existing `anyio.abc.BlockingPortal` deprecation warning. These checks did not start or stop the application services, load a real model, use the GPU, or open a browser.

## Independent scoped re-review (2026-09-12)

Reviewed `artifacts/macos/review-fixes.patch` and the corresponding current files. Both original P2 findings are resolved by inspection: empty-state media time now triggers rotation with batch splitting and retained overlap, and Darwin process ownership uses argument-preserving `KERN_PROCARGS2` inspection. The translation design record is corrected. The coordinator's focused verification log records 28 passing CPU tests. The complete regression and real-model/browser acceptance remain coordinator-owned.

One new P2 correctness issue was confirmed in the silence-filter change:

### [P2] Preserve Silero-confirmed quiet speech in the no-speech output filter

Location: `<workspace>/VoxBridge/voxbridge/cli/demo_streaming_ws.py:6779` (`_mlx_candidate_has_no_speech_evidence`).

The filter equates absence of energy-detector activity with absence of speech. Silero rescue deliberately handles speech missed by that energy detector, but positive Silero observations do not set `backend_vad.in_speech` or `segment_active_ms`. Consequently, the new filter clears both partial and final ASR text for a quiet speaker even when the enabled Silero observer positively confirms speech. The filter needs persistent per-segment speech evidence from either detector, retained for finalization and reset at segment rotation, while continuing to reject model output from windows with no evidence of speech.

CPU-only WebSocket reproduction used the existing fake ASR and real `SileroShadowObserver` wrapper with neural probability fixed at 0.99. One second of PCM16 samples with value 131 is about -48 dBFS: below the initial energy detector's 8 dB SNR entry threshold but above the browser's absolute -50 dB silence ceiling. With the fake ASR returning `请大家一起祷告。`, the unchanged vLLM integration emitted that partial and final text; the MLX integration emitted no partial and an empty final. The same positive neural observation and waveform were used for both. No model, GPU, browser, or service was started or changed. The present high-amplitude 0.5-second Stop-tail test does not cover this disagreement between detectors.

The raw-PCM continuity correction itself is consistent with the supplied controlled A/B evidence: all received binary PCM reaches MLX rather than leaving an initial pre-speech gap. The new output filter still requires the P2 correction above before this re-review can give an unqualified approval. No additional P0/P1 issue was identified.

### [P2] Respect a deferred silence barrier when coalescing the split remainder

Location: `<workspace>/VoxBridge/voxbridge/cli/demo_streaming_ws.py:11544` (`_coalesce_audio_frames`, in combination with `_split_empty_mlx_batch_at_hard_cut`).

The stricter split keeps the expected state generation and balances the restored `queue_samples`, but introduces an ordering case: coalescing first removes a silence control span from the audio queue and defers it; splitting then inserts the remaining PCM before that span. On the next iteration, coalescing the remainder reads newer PCM directly from `audio_queue`, bypassing the still-deferred silence barrier. The server therefore observes later speech before the earlier silence, potentially applying an endpoint to the wrong speech. Coalescing must respect all earlier deferred items before drawing fresh queue entries.

CPU-only reproduction executed the exact current helper functions extracted from the source AST. With 11.5 seconds of elapsed segment time, one second of marker-1 PCM, and an audio queue containing one second of silence followed by one second of marker-2 PCM, the split returned an 8,000-sample prefix. The subsequent coalesced remainder contained 24,000 samples with both markers `[1.0, 2.0]` while the silence span was still deferred. Queue accounting ended at zero; the defect is control/audio ordering, not sample loss. This scoped finding was sent to the coordinator and split owner for correction before the final verdict.

## Final scoped verdict (2026-09-12)

**Approved within the reviewed scope. All four concrete P2 findings above are resolved; no actionable finding remains in these changes.** This verdict follows inspection of both owners' frozen corrections and independent focused CPU verification.

- The silence-output filter now accepts persistent positive Silero evidence as well as energy-detector activity. Evidence resets on session start and segment rotation. Repeating the exact original quiet-PCM WebSocket A/B now gives both backends the partial and final `请大家一起祷告。`. The new regression also verifies that evidence survives a quiet tail through finalization, then resets so a later all-zero segment cannot publish an arbitrary `嗯。`.
- Coalescing now returns the current PCM whenever an earlier deferred item remains. This preserves the silence barrier and PCM order after a hard-cut split. The marker/count regression verifies positive-marker audio precedes negative-marker audio, no ASR call mixes the two sides of the silence barrier, and all source PCM is consumed. Remainder accounting is balanced and internal segment rotation preserves the generation of deferred PCM.
- Empty hypotheses remain bounded with batch splitting, retain overlap, and recover when recognizable speech arrives later. Exact Darwin argv ownership and the corrected translation design settings remain accepted.

Independent final verification:

```text
../.venv/bin/python -m pytest -q \
  tests/test_mlx_backend.py::test_mlx_stop_keeps_short_tail_when_silero_observed_quiet_speech \
  tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_split_remainder_does_not_coalesce_across_client_silence \
  tests/test_demo_streaming_ws_protocol.py::test_ws_mlx_rotates_empty_audio_windows_and_recovers_with_later_speech
3 passed, 1 existing dependency deprecation warning in 0.51s
```

This approval covers code/spec correctness of the scoped migration and review corrections. It does not substitute for the coordinator's final managed-service restart, real-model chain, browser/audio, and complete regression acceptance evidence. Review actions did not start or stop services, import a GPU runtime, or operate a browser.
