# Source coverage and speech confirmation

The local pipeline keeps Qwen3-ASR 0.6B MLX INT8, HY-MT1.5-1.8B Q8_0,
the verified prompts, and Kokoro. Chinese speech adapts between 1.2–1.5×.

## Problem

The September 28 browser/system-audio evaluation found that translation itself
usually finished in about half a second. Some prepared speech waited over ten
seconds. It also found incomplete English complements translated independently,
and a source revision plus a subsequent row covering the same spoken words.
Longer waiting alone cannot fix a semantically incomplete translation input.

## Responsibilities

- `streaming/semantic_units.py` repairs narrowly identified dependent phrases.
  Quantifiers after *need/require*, unfinished *to be*, and open objects such as
  *confidence in* stay with their complement. Ordinary questions and stranded
  prepositions retain their boundaries. Existing Chinese clause rules remain.
- `streaming/source_ledger.py` assigns token occurrence identities within an
  ASR window. Ordered alignment follows revisions. An exact old suffix/new
  prefix can retain identity across a window only when supplied as an explicit
  carry. New windows otherwise allocate new identities, even for identical text.
  Bindings and immutable published coverage are bounded to 256 entries each.
- `interpretation/source_commit.py` coordinates repaired source units, coverage,
  decoder evidence, and lookahead. A repaired unit can be confirmed even when
  removing an incorrect period makes it differ from the raw ASR substring.
- `streaming/english_units.py` builds on the submission dependency/complement
  rules to assess early speech confirmation. A comma alone is not
  enough: a positive subject/predicate pattern, closed complement, and a
  following independent clause are required for early speech. Unsupported
  clauses wait for normal source finalization before speech. The existing
  submission granularity is retained: applying the stricter positive grammar
  to submission itself merged too much text in the paired browser test.
- `tts/confirmation.py` counts actual decode keys, never monitor polls. Words
  and punctuation boundaries have separate evidence. Punctuation changes keep
  word history but require two fresh matching boundary observations. Negation,
  numbers, and name hints keep the stronger three-decode word requirement and
  cannot use urgent release. Comma clauses also need three word observations.
- `tts/jobs.py` remains the release owner. Translation completion does not reset
  the source clock. Preparation is reversible; the first shared PCM commit is
  irreversible. The existing quiet windows, ordered release, revision checks,
  and native-player feedback remain in force. An exact confirmed revision may
  reuse its already-observed word AND boundary age, including evidence obtained
  before translation registration. A changed or withdrawn revision loses this
  confirmation credit. Translation-ready time never supplies source evidence.

The ledger suppresses a new candidate only when its complete occurrence range
is already owned by a source row or published speech. It does not globally remove
equal strings. Ambiguous/unmatched text falls back to the existing reconciliation
and finalization path. A carried-only prefix does not gain fresh decode votes.

Late additions have a separate pending record. Preparing their translation or
audio does not advance spoken coverage: only publication does. A newer parent
revision cancels the obsolete unpublished addition and recomputes its suffix
from the actually spoken prefix. Final reconciliation can correct words inside
that unpublished suffix while preserving the published prefix. Contraction to
an already spoken prefix alone does not discard an addition that may have moved
to a following ASR row during resegmentation.

## Diagnostics

`GET /api/native/diagnostics` is a read-only loopback endpoint using the existing
`X-VoxBridge-Control-Token` authorization. It returns bounded pending revisions,
source quiet age, translation-ready age, confirmation/ordering/offer state,
release policy, and fresh native playback feedback. It does not join a listener,
refresh feedback, advance source clocks, or publish audio. Never expose the token
in reports, URLs, or logs.

Optional subtitle tracing adds `tts_confirmation_wait` with alignment,
dependency, decode-agreement, or lookahead reasons, and `source_range_covered`
when an overlapping source occurrence is suppressed. The native feedback contains
received/played chunk sequence and buffer duration, not sample-accurate physical
speaker onset. Server PCM publication must not be reported as audible onset.

Pending diagnostics also include `decode_hits`, `boundary_hits`, `required_hits`,
and `boundary_kind`. `source_quiet_age_ms` is the effective validated source age
used by the release gate; it may include observations before registration, and
must not be interpreted as time since translation completion.

## Verification and limits

Regression tests cover cross-window incomplete quantifiers, missing confidence
objects, repaired-text confirmation before finalization, actual repeated phrases
in both Chinese and English, numeric/negative revisions, stale prepared audio,
and short final sentences released after the existing silence guard. Native PCM
regressions compare the complete source, monitor speech records, and the actual
audio publication jobs. Real repetition, a final tail, and late source additions
must survive release and shutdown, rather than merely remain visible as text.

These are conservative local rules, not a complete syntax parser. They do not
guarantee perfect semantic completeness or eliminate necessary lookahead. General
latency or accuracy gains require paired fixed-source live tests. Speculative
translation stays disabled; the earlier same-Mac experiment did not demonstrate
a meaningful speech-onset improvement from enabling it.

The subsequent browser/system-audio comparison on September 28 did not establish
a publication latency improvement: translation-visible to first server PCM was
3.09 s median / 10.37 s P95 before, versus 3.15 s / 11.04 s after. These were
single browser runs with slightly different endpoints, not identical PCM input
replays. The final 10 min 33 s run accounted for all 103 submitted source units
and 122 published PCM chunks; native feedback confirmed all chunks played and
the queue drained. This checks submitted-source coverage, not ASR transcription
accuracy. The final full suite passed 1360 tests, with 32 skipped. Revision and
resegmentation alignment remain the next latency bottleneck to investigate;
these safeguards must not be presented as a demonstrated overall speedup.
