# Speech and caption consistency

**English** | [简体中文](../zh-CN/SPEECH-CONSISTENCY.md)

Starting with App 1.6.1 (build 19), native interpretation distinguishes completed translation, permission to publish, and actual audio commitment. Translation and speech synthesis can start early. Chinese retains complete semantic units; pinned models, voices and automatic speed settings remain unchanged.

## Publication rules

1. Source edits create a new revision and invalidate its previous streaming confirmation and final seal. Confirming a later sentence does not automatically confirm a recently edited earlier sentence.
2. Translation can be synthesized ahead of publication. Unshared audio remains replaceable, while publication preserves source order. The next sentence can be prepared during playback of the previous one.
3. The first shared PCM commit locks the entire sentence revision. Native PCM, HLS audio and playback captions use the same text snapshot. Shared audio is not withdrawn, replayed or rewritten.
4. If the actual decoder withdraws an unspoken sentence, confirmation is revoked. Reconfirmation must satisfy the current stability window; an older task waiting for encoder capacity cannot bypass it.
5. Capture finish reconciles source text and translation, then drains the remaining sentences in order. A synthesis failure releases the head so later speech can continue.

## Early confirmation for English sources

Early confirmation requires a suitable source boundary, agreement between distinct decoder results, and enough following tokens to move beyond the ASR rollback window. Text retained solely to prevent display regression is not decoder evidence. Repeated processing of one decode does not add agreement.

- Ordinary complete sentences require at least two agreeing decoder results.
- Negation, numbers and internal capitalization suggesting proper names require at least three, using the normal stability window rather than the low-buffer urgent shortcut.
- Unclosed quotes or parentheses, apparent unfinished dependent clauses, and missing boundaries wait for final recognition.
- The default normal window remains 3 seconds. Eligible confirmed sentences can use 1 second when native playback has at most 2 seconds buffered. Translation and preparation overlap this time; a final source seal removes additional timer waiting.

These conservative hints are not a full grammar parser or named-entity recognizer. Final ASR errors, translation errors and semantic changes after publication remain possible. Zero latency with perfect future agreement is not guaranteed.

## Reading the output

- With native output enabled, the App translation area and desktop captions follow actual playback.
- The listener page continues to select captions from the HLS playback clock; translation revisions do not directly advance its caption.
- The monitor preserves submitted text as the published speech record and exposes later revisions separately. Pending text is labeled as awaiting confirmation. The monitor is not a playback-position caption view.
- With native output explicitly disabled, the App can display the latest completed translation. This does not represent another LAN device's playback position.

Capture, translation and native playback remain independent of browser pages.

## Short English quotations

The 2026-09-15 service update recognizes paired straight/curly single and double quotes. When an introduction and complete short quotation fit the current 18-word chunk, surrounding commas, semicolons and colons no longer force a separate synthesis; ordinary clauses within that quotation can also stay together. Sentence stops retain their existing behavior. Quotations that do not fit, and unclosed quotes, retain the previous splitting rules.

This does not remove quote characters, alter translation text or increase stabilization waits. Contraction apostrophes are not quotation marks. Ambiguous or nonstandard typography may still use the original splits; this is not a complete English grammar parser. Chinese and other language splitting are unchanged.

Validation on 2026-09-15: 1,039 tests passed; six optional checks were skipped because the ONNX converter, Playwright or ffprobe were unavailable. A captured 16-word example changed from two Kokoro synthesis calls to one. Its 5,013 ms PCM output exactly matched the whole-sentence reference at the same voice and speed; the shared-output regression also retained the complete caption. This removes the forced synthesis break, while normal punctuation prosody can remain.

## Development boundaries

`RevisionStableTTSBuffer` tracks confirmation per revision and retains a replaceable head until the first native PCM commit. `SharedSpeechOutput` carries invalidation, commit guards and callbacks. `SharedHLSTTSPublisher` retains atomic PCM/HLS commitment. `SpeechConfirmation` handles text/decode evidence without inference or audio scheduling.

Compatibility broadcast jobs are sent on actual shared commitment, including tails committed after capture ends. Explicit private pull clients retain job publication as their irreversible boundary because audio can be claimed as soon as the job is sent.

Regression coverage includes revisions, raw decoder withdrawal, negation/numbers, blocked encoding, reconfirmation, same-revision retries, ordering, final draining and compatibility notifications. Real-model and native-playback measurements are documented in the [1.6.1 validation report](VALIDATION-1.6.1.md).
