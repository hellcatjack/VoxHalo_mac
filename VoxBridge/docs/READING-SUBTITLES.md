# Reading-first subtitles

The native App offers **Reading first** (default) and **Follow speech** in Subtitle
settings. **Build 43 makes Reading first independent of audio**: a completed
translation can enter the visible queue before speech confirmation, synthesis or
PCM delivery. Follow speech still shows the currently audible segment. Models,
prompts, speech confirmation, synthesis speed, PCM bytes and playback scheduling
are unchanged. The local web listener retains playback-synchronized captions.

The overlay contains translations only, with no mode labels, operational notices,
or partial token generation. It uses the selected fixed font size, natural
wrapping, and spaces in place of source newlines. The App separately shows the
text currently being spoken. A later completed correction can therefore differ
from an older translation still being spoken; choose Follow speech when matching
the audible wording matters more than seeing a completed translation early.

## Independent reading clock

- A complete, stable `sentence_translation` for the current source revision is
  eligible immediately, with no dependency on accepted or playing PCM. An
  isolated very short result can gather neighboring text for **at most 0.4 s
  from translation completion**; time already spent waiting counts toward that
  bound. End of input removes this gathering delay.
- Screens follow source insertion order. A later completed result cannot jump
  over an earlier unresolved translation. Already-ready neighboring rows share
  a screen at the next boundary if they fit at the selected font size and within
  the target language's reading budget. Sharing charges the minimum once.
- Once shown, the entire screen's text, identity, layout and deadline stay fixed.
  Incoming text is not appended mid-screen. After its reading time ends, the
  next ready screen replaces it on the independent 50 ms presentation clock;
  there is no wait for an audio chunk or another silent interval.
- Chinese and Japanese use `max(3, reading_work / 1.35)` seconds, plus a bounded
  dense-text allowance. Reading work is `CJK characters / 6 + other-script
  words / 3`. The allowance is 0.05 s per Han character beyond 24, capped at
  1.5 s per screen; Japanese also counts kana. It is charged once to the whole
  screen. **Speech speed and queued audio do not shorten these budgets.**
- Chinese/Japanese screens have a work limit of 10 (approximately **60 pure
  CJK characters**), in addition to actual fixed-font geometry. A pure Chinese
  30-character screen gets about 4.0 s, 40 gets about 5.7 s and 60 about 8.9 s.
  Longer translations continue on complete subsequent pages without truncation.
- English uses `max(3.5, 0.2 + words / 4.8)` seconds from build 44: a fixed
  288-word/minute pace with a **3.5-second minimum**, independent of speech or
  backlog. Its work limit remains approximately 36 words. Complete-word
  boundaries and balanced long-text pages avoid charging a full minimum hold
  for a tiny leftover tail. If actual font geometry subdivides those pages, the
  queue compares semantic-first and physical-first candidates and keeps the
  lower total reading cost, after lossless-content, fit and word-limit checks.
  Current visible screens keep their entire budget. An identical translation
  retains its actual read cursor even after manual font reflow, including a
  completed fallback waiting for a newer source revision's translation.
- French, Spanish, Italian, Portuguese and Hindi keep their separate original
  `max(3.5, 0.5 + words / 3.5)` policies and approximately 36-word screen limit.
  Mixed CJK consumes proportional reading work; contractions remain one word
  and Indic combining marks stay with their word. These are engineering defaults,
  not a universal reading-speed claim. Large fonts, slower readers or sustained
  input above visual capacity can still require a reading queue.
- Long text paginates at punctuation/word boundaries and the user's actual font
  and display capacity. Every non-whitespace character is retained. There is no
  automatic font shrinking, inserted newline or second overlay pagination timer.
  Manual font/display changes reflow visible and unread text with full reading
  time. Hiding captions or switching to Follow speech pauses the independent
  reading clock, while audio continues; returning preserves remaining time.
- The last caption stays visible. Completed history alone is bounded within the
  queue; unread content is never evicted to catch up. Reading may continue after
  capture/audio stops without delaying audio shutdown. A new session resets it.

## Revisions and source continuity

- An identical completed revision preserves read and visible page progress.
  A changed translation, including number or negation corrections, gets a full
  later reading turn rather than changing words under the reader's eyes.
- Distinct source occurrences with identical words remain separate. Exact
  source token IDs **within the same ledger epoch**, plus exact word-bounded
  target text, can prove an already-displayed occurrence is covered. This is not
  fuzzy or global text deduplication. Unknown bindings retain full text.
- Source retirement rejects late obsolete events but keeps an already completed
  unread visual fallback until its replacement MT succeeds. If new MT fails,
  a completed previous version remains readable. Failure records are separate
  from queue exhaustion and never appear as subtitle text.
- Final source-ledger rebuilds freeze the current reading turn. A complete
  snapshot proving the entire ordered canonical source is unchanged can retain
  exact prior reading progress across new segmentation. Corrected or unprovable
  rebuilds stage the new visual rows until the final result. All new rows must
  have complete MT and exact source-range coverage before replacing old unread
  fallback; otherwise known complete old text is retained, followed by complete
  successful corrections. Ambiguous overlap is never cut by source/target length
  ratios. Such a conservative correction can repeat context.
- Reset snapshots are presentation metadata only. Oversized snapshots are omitted
  atomically and take the conservative fallback path. They never alter ASR,
  translation confirmation, source-ledger decisions or speech jobs.

If input persistently exceeds reading capacity, delay can still grow. Keeping
all completed content and minimum reading time takes priority over silently
skipping unread captions. This change removes audio-related display waits; it
cannot remove the time needed to recognize and translate speech, or guarantee
that every failed source produces a translation. An explicit MT failure stays
in the App/monitor and does not block all later completed captions.

## Reading history

Open **Reading history** with the console's book button or the App/menu-bar menu.
The separate native window shows numbered source text and completed full
translations in a selectable, scrollable text view. It retains final complete
translation results and completed corrections,
including previous completed versions while a newer source revision waits for
translation. Identical retransmissions do not add duplicate entries; distinct
source occurrences with identical words remain separate. Draft, stale and
invalid translation events are ignored. Entries follow source insertion order,
with each occurrence's recorded corrections kept together.

Accepted incremental speech that is not covered by the full sentence translation
is also retained in its exact accepted wording as **Spoken supplement**. Only
the accepted supplement's complete sentence text is recorded, not each PCM chunk
or repeated schedule snapshot. It stays with its original source occurrence
when that binding is known, including after source-ledger resets. Distinct
occurrences with the same words remain separate. When the original source delta
cannot be reliably identified, the record shows the supplement translation only;
it does not label the full parent source as that delta.

There is no completed-entry eviction limit within the current session. New
entries preserve the selected passage and scroll position; the window follows
the end only when the reader was already there. The record stays available after
stopping and clears when the next session starts. An in-session source-ledger
reset for final re-decode or reconciliation retains completed records; rebuilt
occurrences receive separate history identities even if source IDs are reused.
It lives in App memory and is **not durable across App relaunches**. Opening or
reading history has no audio, model or browser side effects.

## Native audio finish limits

After final translation flushing, the native audio drain follows published PCM
and actual playback completion. Unpublished speculative pre-synthesis and HLS
mirror buffering do not count as native speech waiting to play. Delivery and
playback progress keep the drain active; a sample clock running through silence
alone is not progress. The drain stops after **60 seconds without progress** or
its **180-second hard limit**, and reports the timeout.

These limits apply to the native audio drain, not to unlimited processing of an
arbitrarily large input backlog. They do not guarantee that every source utterance
will be translated and played under all backlog or failure conditions. Completed
translations, corrections and accepted supplements already in Reading history
remain readable after stopping. The history feature does not alter synthesis,
PCM bytes or playback scheduling.

## Source units before translation

For Chinese/English, neighboring **already available, finalized and not yet
submitted** short sentences can share a translation input. Live revisable or
already-submitted source rows retain their existing boundaries: regrouping them
would interfere with positional revision reconciliation. Display grouping does
not have that restriction because it preserves the separate source identities.
The source grouping target uses fewer than 10 CJK
characters or 6 words as a hint; both neighboring units must be short. English
grouping conservatively uses pronoun-led units; other constructions retain their
existing boundaries. A combined unit is bounded to 32 characters or 24 words.
Complete short acknowledgements, negatives and urgent commands are
exempt, and a question/exclamation does not absorb its following answer. Open
complements remain subject to the existing semantic repair rules.

This stage adds no timer: it uses context already recognized. Submitted source
boundaries are locked as later text arrives. The newest completed unit remains
separate for the existing lookahead/holdback mechanism. If a prefix changes, grouping defers
to the existing revision reconciler. Punctuation and repeated occurrences are
preserved; grouping is not string deduplication. Speech confirmation and the
1.2–1.5× Chinese synthesis policy remain unchanged.
