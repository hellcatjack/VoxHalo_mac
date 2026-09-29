# Reading-first subtitles

The native App offers **Reading first** (default) and **Follow speech** in Subtitle
settings. The setting is presentation-only: changing it, moving/hiding captions,
or reading a longer page does not publish, consume, seek or cancel speech jobs.
Follow speech retains the actual PCM playback clock. The local web listener
continues to show playback-synchronized captions.

Reading first consumes completed `sentence_translation` events at the current
source revision. These results can still be revised; Subtitle settings explains
this behavior. The overlay contains translation only, without mode labels or
operational messages. It never exposes partial token generation. The App separately shows the text
currently being spoken, so the two timelines are not mislabeled as one.

## Timing and completeness

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
  Japanese use this work divided by a
  visual pace factor initially set to 1.35. Accepted complete PCM units provide
  read-only duration feedback: the last 12 units set a pace 20% ahead of measured
  speech, bounded to 1.35–2.2. At least four waiting ready rows allow a further
  15% increase, capped at 2.5. This affects new display deadlines only and never
  changes speech speed, scheduling or an already-visible group's minimum.
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
