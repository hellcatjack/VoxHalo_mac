# Reading-first subtitles

The native App offers **Reading first** (default) and **Follow speech** in Subtitle
settings. Build 40 uses native PCM playback progress for live Reading first
captions and keeps a separate full-session reading history. These are
presentation features: changing mode, moving/hiding captions or opening history
does not publish, consume, seek or cancel speech jobs. Models, prompts, synthesis,
audio bytes, scheduling and browser listening are unchanged. The local web
listener continues to show playback-synchronized captions.

The overlay contains translation only, without headings, mode labels or
operational messages. It never exposes partial token generation. Captions keep
the selected font size and wrap naturally. The App separately shows the text
currently being spoken.

## Live Reading first with native local speech

- The live card uses immutable sentence text accepted by the native PCM player,
  rather than a newer translation revision that may differ from the audible
  sentence. It advances from the player's actual output sample position,
  including its presentation-latency adjustment.
- Once upcoming audio is scheduled, a new card is eligible approximately
  **0.6 seconds before its first PCM anchor**. This is an intended lead, not an
  end-to-end timing guarantee. The first packet can arrive as speech begins, so
  the first caption may appear simultaneously. Network delivery, UI scheduling
  and device latency can reduce the lead.
- Complete neighboring short sentences can share a card if they are already
  scheduled, adjacent and fit at the chosen font size. The card's text and
  identity stay frozen; incoming sentences and revised translations do not
  append words or rewrap that card. Grouped later sentences may appear farther
  ahead than the first card anchor.
- Long sentences paginate at the user's fixed font size. Page positions follow
  accepted PCM chunk boundaries and proportional text work within each chunk.
  A long sentence synthesized as a single chunk therefore has approximate page
  positions: there is no word-level audio alignment. Only scheduled PCM can
  establish a future page position; an unknown synthesis or starvation gap is
  not predicted.
- Paused output holds the card; receiving more audio while the sample position
  stays unchanged does not replace an existing card. Hiding captions does not
  pause this playback clock. Restoring captions follows the current position;
  a suspended UI catches up rather than replaying an obsolete visual backlog.
  Manual font/display changes reflow at current speech progress, without
  rewinding spoken pages or restarting an independent reading timer.
- Live cards prioritize playback progress. There is **no universal 3-second or
  3.5-second minimum hold** when fast speech or several long-sentence pages must
  fit the existing audio duration. Complete history remains available for
  reading; retaining the text is not a promise that every live page received
  enough reading time. Full minimum holds, finite display space and unchanged
  audio cannot also guarantee keeping up with arbitrarily fast speech.
- **Follow speech** remains tied to the currently audible PCM segment. Live
  Reading first keeps its last card after stopping and does not replay the
  independent fallback queue accumulated during local speech.

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

## Reading timers without native local PCM playback

When native local playback is unavailable, including **Do not play locally**,
Reading first retains the independent reading queue described below. It consumes
completed `sentence_translation` events at the current source revision. These
results can still be corrected. The language-specific minimum holds and hidden
clock pause apply to this fallback, not to live PCM captions.

- Pages follow source insertion order, not translation completion order. A later
  result cannot overwrite or leapfrog an untranslated earlier sentence.
- At each page boundary, already-ready groups fill the available space at the
  selected font size. Once shown, the whole screen's text, identity and reading
  deadline are frozen. New translations and corrections wait for the next screen;
  they never append words or change wrapping while the current screen is read.
  Reading work is accounted for in source order. Groups assembled together share
  the target language's minimum hold rather than each adding a separate minimum.
- Groups on the same screen retire together after all their reading budgets
  have elapsed. Removing a preceding group must not reflow its already-visible
  suffix into a second, standalone caption. The next screen contains unread
  content; a repeated sentence with a distinct source identity still appears.
- Reading work is `CJK characters / 6 + other-script words / 3`. Chinese and
  Japanese use this work divided by a visual pace factor initially set to 1.35.
  At least four waiting ready rows allow a 15% display-pace increase, capped at
  2.5. The retained queue can also use read-only speech-duration feedback when
  available; a session without local PCM has no such samples. These adjustments
  affect new display deadlines only and never change speech speed, scheduling
  or an already-visible group's minimum. Live PCM captions use the sample clock
  described above rather than this reading-rate estimate.
  Punctuation/whitespace do not add words; contractions remain one word. These
  are engineering defaults, not a universal reading-speed assertion.
- Chinese target screens retain their extra reading allowance after the
  paced duration and shared 3-second minimum: 0.05 seconds per Han character
  beyond 24, capped at 1.5 seconds per screen (40 characters: +0.8 s;
  60 characters: +1.5 s). Count the whole visible screen once, including
  grouped short sentences. Japanese uses the same initial parameters, counting
  both Han and kana. This allowance never modifies speech or mid-screen deadlines.
- English, French, Spanish, Italian, Portuguese and Hindi have separate policy
  entries, initially `max(3.5, 0.5 + word_count / 3.5)` seconds for the whole screen.
  The 0.5-second orientation allowance is charged once, not per grouped sentence.
  Mixed CJK text consumes proportional reading work as well. Combining marks in
  Hindi stay with their word; apostrophes do not split contractions. Their visual
  clock is independent of PCM speech feedback and backlog acceleration.
- Those six word-based policies limit the **entire** screen to approximately
  36 words (72 CJK-equivalent characters for mixed text), in addition to the
  actual fixed-font capacity. Other ready groups wait for the next screen, with
  no truncation, smaller font or forced newlines. Each target language has its
  own defaults; changing French, for example, does not change English.
- Neighboring short translations can share a page up to approximately 72 CJK
  characters or 36 words, subject to the actual fixed-font display capacity.
  An isolated short result can gather for at most 0.4 s
  from completion; time already spent in the queue consumes that budget. EOF
  removes this gathering delay.
- Long translations are paginated at natural punctuation/word boundaries and
  retain every non-whitespace character. Each page gets its own minimum time.
  The reading queue also measures pages against the selected font and display.
  It serializes groups that cannot fit together; it does not shrink the font or
  run a second pagination timer. Manual font/display changes reflow unread and
  currently visible pages with full reading time.
- All captions keep the exact selected font size. They use natural width-based
  wrapping; source line breaks and group separators become spaces for display.
  No headings, blank lines or forced line breaks are inserted. This normalization
  never changes stored translations or TTS input. Oversized Follow speech captions
  can paginate at the same size without controlling or delaying audio playback.
- A displayed group's reading budget is not shortened by newer translations;
  it can remain alongside its neighbors until the whole screen is complete.
  A correction gets a subsequent complete reading turn; an identical translation
  at a new source revision preserves its visible and already-read page progress,
  including multi-page translations. Distinct source sentences with the same
  text retain their separate reading turns. Stale results are ignored.
- Completed translation events may include `source_token_ids`, a read-only copy
  of the source ledger's occurrence binding. A fully displayed translation can
  cover a later resegmented row only if both its contiguous source occurrence
  IDs and its exact, word-bounded translated text are covered. Coverage includes
  groups accepted onto the same frozen screen, but never deferred or unread
  pages. Known overlap is recorded in `coveredVersions` for verification.
  An exact sentence-ending prefix of a fully displayed same-source revision
  can be removed from its extension. Rephrased translations, negation/number
  changes, missing bindings and new occurrences retain their full text. This
  is not fuzzy or global string deduplication. Metadata does not commit, cancel,
  reorder or otherwise change speech jobs.
- Hiding reading captions or switching to Follow speech pauses the reading clock;
  it does not pause audio. Restoring reading captions preserves remaining time.
- Only completed history is bounded. Unread/unfinished rows are never evicted to
  catch up. Final text remains visible. Reading can finish after capture stops,
  without holding up audio shutdown. Starting a new session explicitly resets it.

If input persistently exceeds reading capacity, delay can grow. Preserving all
content and minimum reading time takes priority over silently skipping a queue.
This is not an ASR/translation accuracy guarantee. An explicit translation
failure stays in the monitor with its source record; it does not insert a notice
into the subtitle area or block all later captions. A successful later retry
can still enter the reading queue. An unfinished translation
still holds its place until a result or failure is known.

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
