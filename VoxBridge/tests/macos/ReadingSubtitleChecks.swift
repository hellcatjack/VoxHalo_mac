import Foundation

private func source(_ id: String, _ revision: Int = 1) -> [String: Any] {
    ["type": "sentence_committed", "sentence_id": id, "revision": revision, "text": id + "-\(revision)"]
}
private func translated(_ id: String, _ text: String, _ revision: Int = 1) -> [String: Any] {
    ["type": "sentence_translation", "sentence_id": id, "revision": revision, "translation": text, "is_stable": true]
}
private func occurrence(_ id: String, _ text: String, _ tokens: [Int], _ revision: Int = 1) -> [String: Any] {
    var event = translated(id, text, revision); event["source_token_ids"] = tokens; return event
}

private func checkLanguageTimingAndCoverage() {
    let samples = ["en": "Don't split 'quoted words' here.", "fr": "L’homme n’est pas encore arrivé.",
                   "es": "Esta es una frase completa.", "it": "Questa è una frase completa.",
                   "pt": "Esta é uma frase completa.", "hi": "यह एक पूरा हिन्दी वाक्य है।"]
    assert(abs(SubtitleReading.work(samples["hi"]!) - 2) < 0.001, "Hindi marks split complete words")
    assert(SubtitleReading.work("हिंदी क्ष त्रि café l’homme don't") == 2)
    for (language, text) in samples {
        let policy = SubtitleTimingPolicy.wordLanguages[language]!
        assert(policy.seconds("Hi.") == 3.5)
        assert(abs(policy.seconds(Array(repeating: "word", count: 26).joined(separator: " ")) - (0.5 + 26 / 3.5)) < 0.001)
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: language)
        q.observeSpeech(text: String(repeating: text + " ", count: 6), seconds: 0.6)
        var seen = Set<String>()
        for n in 0..<150 {
            let id = "row-\(n)"
            q.observe(source(id), now: 0)
            q.observe(translated(id, text), now: 0)
        }
        q.observe(["type": "final"], now: 0)
        var now = 0.0
        while q.pendingCount > 0 {
            guard q.advance(now: now) else { assert(q.pendingCount == 0); break }
            let frozen = q.text, deadline = q.deadline, identity = q.identity
            assert(SubtitleReading.work(q.text) <= 12 && !q.text.contains("\n"))
            assert(abs(deadline - now - policy.seconds(q.text)) < 0.001)
            seen.formUnion(q.references.map { $0.id })
            q.observeSpeech(text: text, seconds: 0.6)
            assert(!q.advance(now: deadline - 0.001) && q.text == frozen
                   && q.deadline == deadline && q.identity == identity)
            now = deadline
        }
        assert(seen.count == 150 && q.displayedPages == 150, "Word limit dropped an unread source")
    }

    let first = "We have a plan.", tail = "We will meet tomorrow."
    let combined = first + " " + tail
    var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
    q.observe(source("parent"), now: 0)
    q.observe(occurrence("parent", first, [1, 2, 3, 4, 5]), now: 0)
    assert(q.advance(now: 0.4)); let end = q.deadline
    q.observe(source("parent", 2), now: 1)
    q.observe(occurrence("parent", combined, Array(1...9), 2), now: 1)
    q.observe(source("child"), now: 1)
    q.observe(occurrence("child", tail, Array(6...9)), now: 1)
    assert(!q.advance(now: end - 0.001) && q.text == first)
    assert(q.advance(now: end) && q.text == tail, "Exact displayed prefix or covered child repeated")
    assert(q.coveredVersions.contains { $0.id == "child" && $0.coveredBy == "parent" })
    q.advance(now: q.deadline); assert(q.pendingCount == 0)
    // The same words at another audio occurrence are intentional repetition.
    q.observe(source("real-repeat"), now: end + 10)
    q.observe(occurrence("real-repeat", tail, Array(20...23)), now: end + 10)
    assert(q.advance(now: end + 11) && q.references.contains { $0.id == "real-repeat" })
    // Same source, different translation: retain negation/number corrections.
    let correction = "We will not meet tomorrow; meet on the 15th."
    q.observe(source("parent", 3), now: end + 11)
    q.observe(occurrence("parent", correction, Array(1...9), 3), now: end + 11)
    assert(q.advance(now: q.deadline) && q.text == correction)
    q.observe(source("parent", 4), now: q.deadline)
    q.observe(occurrence("parent", first, Array(1...9), 4), now: q.deadline)
    assert(q.advance(now: q.deadline + 0.4) && q.text == first,
           "A shorter correction of a complete occurrence was mistaken for an overlapping child")
    q.observe(source("parent", 5), now: q.deadline)
    q.observe(occurrence("parent", combined, Array(1...9), 5), now: q.deadline)
    assert(q.advance(now: q.deadline + 0.4) && q.text == combined,
           "Reverting a correction was suppressed by an obsolete displayed version")

    // No occurrence evidence: fail open, never guess that equal text is a duplicate.
    q.reset(targetLanguage: "en")
    for id in ["a", "b"] {
        q.observe(source(id), now: 0); q.observe(translated(id, tail), now: 0)
    }
    q.advance(now: 1); assert(q.text == tail + " " + tail && q.displayedPages == 2)

    // A deferred short screen has not covered its child yet. Revising it during
    // coalescing must not accidentally consume a child that was never displayed.
    q.reset(targetLanguage: "en")
    for id in ["a", "b"] {
        q.observe(source(id), now: 0); q.observe(occurrence(id, first, Array(1...5)), now: 0)
    }
    assert(!q.advance(now: 0.1) && q.coveredVersions.isEmpty)
    q.observe(source("a", 2), now: 0.2)
    q.observe(occurrence("a", "Another plan.", Array(30...32), 2), now: 0.2)
    assert(q.advance(now: 0.6) && q.text.contains(first) && q.text.contains("Another plan."))
    assert(q.coveredVersions.isEmpty)

    // A correction cannot prove coverage until all its pages are visible.
    q.reset(targetLanguage: "en")
    q.configure(splitter: { $0.components(separatedBy: " | ") }, fits: { !$0.contains(". ") })
    q.observe(source("long"), now: 0)
    q.observe(occurrence("long", first + " | " + tail, Array(1...9)), now: 0)
    q.advance(now: 1); assert(q.text == first)
    q.observe(source("long", 2), now: 2)
    q.observe(occurrence("long", "A new plan.", Array(40...43), 2), now: 2)
    q.observe(source("unread-tail"), now: 2)
    q.observe(occurrence("unread-tail", tail, Array(6...9)), now: 2)
    q.advance(now: q.deadline); q.advance(now: q.deadline)
    assert(q.text == tail && q.coveredVersions.isEmpty, "Unseen tail was suppressed")
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
    q.observe(source("resize"), now: 0)
    q.observe(occurrence("resize", combined, Array(1...9)), now: 0)
    q.advance(now: 1)
    q.configure(splitter: { $0.components(separatedBy: ". ").map { $0.hasSuffix(".") ? $0 : $0 + "." } },
                fits: { !$0.contains(". ") })
    assert(q.advance(now: 2) && q.text == first, "Occurrence coverage prevented manual reflow")
    assert(q.advance(now: q.deadline) && q.text == tail)
    print("PASS: eight-language timing, fixed English clock, Hindi graphemes, occurrence coverage and safe corrections")
}
@main struct ReadingSubtitleChecks {
    static func main() {
        let migrated = try! JSONDecoder().decode(SubtitlePreferences.self, from: Data(#"{"fontSize":42,"backgroundEnabled":true}"#.utf8))
        assert(migrated.mode == .reading && migrated.fontSize == 42 && migrated.backgroundEnabled)
        var saved = migrated; saved.mode = .playback
        assert(try! JSONDecoder().decode(SubtitlePreferences.self, from: JSONEncoder().encode(saved)).mode == .playback)
        assert(SubtitleReading.seconds("谢谢。") == 3)
        assert(abs(SubtitleReading.seconds(String(repeating: "字", count: 30)) - 5 / 1.35) < 0.001)
        assert(abs(SubtitleReading.seconds("one two three four five six seven eight nine ten eleven twelve fifteen fourteen fifteen") - 5 / 1.35) < 0.001)
        assert(SubtitleReading.work("你好 don't worry") == 1)
        // Dense Chinese screens get a bounded allowance even when fast speech
        // feedback would reduce the base hold to its minimum. No mid-page edits.
        for count in [12, 24, 25, 40, 60, 72] {
            let text = String(repeating: "字", count: count)
            let extra = min(1.5, Double(max(0, count - 24)) * 0.05)
            for fastFeedback in [false, true] {
                var baseline = ReadingSubtitleQueue(), chinese = ReadingSubtitleQueue()
                chinese.reset(targetLanguage: "zh")
                chinese.observe(["type": "started"], now: 0)
                assert(chinese.targetLanguage == "zh", "Session events lost the chosen target language")
                if fastFeedback {
                    baseline.observeSpeech(text: text, seconds: 0.6)
                    chinese.observeSpeech(text: text, seconds: 0.6)
                }
                baseline.observe(source("long"), now: 0); chinese.observe(source("long"), now: 0)
                baseline.observe(translated("long", text), now: 0); chinese.observe(translated("long", text), now: 0)
                baseline.advance(now: 1); chinese.advance(now: 1)
                assert(abs(chinese.deadline - baseline.deadline - extra) < 0.001)
                let held = chinese.deadline, identity = chinese.identity
                chinese.observe(source("next"), now: 1.1)
                chinese.observe(translated("next", "下一句。"), now: 1.1)
                chinese.observeSpeech(text: text, seconds: 0.6)
                assert(!chinese.advance(now: held - 0.001) && chinese.text == text
                       && chinese.identity == identity && chinese.deadline == held)
                assert(chinese.advance(now: held) && chinese.text == "下一句。")
                chinese.advance(now: chinese.deadline)
                assert(chinese.pendingCount == 0 && chinese.displayedPages == 2)
                chinese.reset(targetLanguage: "en")
                assert(chinese.targetLanguage == "en")
            }
        }
        // Chinese and Japanese retain the legacy screen clock; Japanese counts
        // kana in its extra allowance as well as Han characters.
        let dense = String(repeating: "字", count: 35)
        for language in ["zh", "ja"] {
            var grouped = ReadingSubtitleQueue(); grouped.reset(targetLanguage: language)
            grouped.observeSpeech(text: dense, seconds: 0.6)
            for id in ["a", "b", "c"] {
                grouped.observe(source(id), now: 0); grouped.observe(translated(id, dense), now: 0)
            }
            grouped.advance(now: 1)
            assert(grouped.references.count == 3)
            assert(abs(grouped.deadline - 1 - (105.0 / 6 / 2.2 + 1.5)) < 0.001)
            grouped.advance(now: grouped.deadline)
            assert(grouped.pendingCount == 0 && grouped.displayedPages == 3)
        }
        assert(SubtitleReading.additionalSeconds(String(repeating: "あ", count: 40), targetLanguage: "ja") == 0.8)
        assert(SubtitleReading.additionalSeconds(String(repeating: "あ", count: 40), targetLanguage: "zh") == 0)
        checkLanguageTimingAndCoverage()
        assert(SubtitleReading.additionalSeconds("A long English caption stays at its original reading pace.", targetLanguage: "zh") == 0)
        for text in [String(repeating: "完整译文不能丢失。", count: 20),
                     String(repeating: "Don't split 'quoted words' or 1,234.56 dollars. ", count: 30),
                     String(repeating: "日本語の字幕です。हिन्दी पाठ। café français. ", count: 10)] {
            let pages = SubtitleReading.pages(text)
            let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
            assert(compact(pages.joined()) == compact(text), "Pagination lost content")
            assert(pages.allSatisfy { SubtitleReading.seconds($0) >= 3 })
        }
        var q = ReadingSubtitleQueue()
        q.observe(source("first"), now: 0); q.observe(source("second"), now: 0)
        q.observe(translated("second", "Second sentence is already ready."), now: 0)
        assert(!q.advance(now: 1), "Out-of-order completion skipped the first source")
        q.observe(translated("first", "第一句需要足够的时间来完成阅读并且不被后来的译文覆盖。"), now: 1)
        assert(q.advance(now: 1)); let first = q.text, end = q.deadline
        assert(!q.advance(now: end - 0.001) && q.text == first)
        assert(q.text.contains("Second"), "Ready text should fill available space immediately")
        q.advance(now: q.deadline)
        assert(q.pendingCount == 0 && !q.text.isEmpty, "Last caption must remain visible")

        q.reset()
        q.observe(source("a"), now: 0); q.observe(translated("a", "是的。"), now: 0)
        assert(!q.advance(now: 0.399)); assert(q.advance(now: 0.4))
        assert(q.deadline == 3.4)
        let frozenID = q.identity
        q.observe(source("b"), now: 0.5); q.observe(translated("b", "谢谢。"), now: 0.5)
        assert(!q.advance(now: 0.9) && q.text == "是的。" && q.identity == frozenID,
               "New text must not reflow a screen that is still being read")
        q.observe(source("c"), now: 2); q.observe(translated("c", "接下来的一整句话。"), now: 2)
        assert(!q.advance(now: 3.399) && q.text == "是的。" && q.deadline == 3.4)
        assert(q.advance(now: 3.4) && q.text == "谢谢。 接下来的一整句话。" && q.displayedPages == 3,
               "The next screen must group available unread content without repeating the old screen")
        assert(!q.advance(now: 6.399))
        q.advance(now: q.deadline); assert(q.pendingCount == 0)

        // Both groups available before a page is shown share one frozen screen.
        // Neither new text nor an identical source revision may move its words.
        q = ReadingSubtitleQueue()
        q.configure(splitter: { [$0] }, fits: { $0.filter { !$0.isWhitespace }.count <= 12 })
        for (id, text) in [("first", "甲乙丙丁戊。"), ("second", "己庚辛壬癸。") ] {
            q.observe(source(id), now: 0); q.observe(translated(id, text), now: 0)
        }
        q.advance(now: 0)
        assert(q.text == "甲乙丙丁戊。 己庚辛壬癸。" && q.displayedPages == 2)
        let combinedID = q.identity
        q.observe(source("second", 2), now: 1); q.observe(translated("second", "己庚辛壬癸。", 2), now: 1)
        q.observe(source("next"), now: 1); q.observe(translated("next", "下一整屏。"), now: 1)
        for t in [1.0, 2, 2.999] {
            assert(!q.advance(now: t) && q.text == "甲乙丙丁戊。 己庚辛壬癸。" && q.identity == combinedID)
        }
        assert(q.references.first { $0.id == "second" }?.revision == 2,
               "Invisible bookkeeping must follow an identical revision without changing the page")
        assert(q.advance(now: 3) && q.text == "下一整屏。" && q.displayedPages == 3)

        q = ReadingSubtitleQueue()
        for id in ["one", "two", "three"] {
            q.observe(source(id), now: 0); q.observe(translated(id, "不可以。"), now: 0)
        }
        assert(q.advance(now: 0)); assert(q.text == "不可以。 不可以。 不可以。")
        q.advance(now: q.deadline); assert(q.pendingCount == 0 && q.displayedPages == 3)

        q.reset(); q.observe(source("tail"), now: 0); q.observe(translated("tail", "再见。"), now: 0)
        q.observe(["type": "final"], now: 0)
        assert(q.advance(now: 0) && q.deadline == 3, "EOF must flush a short caption")
        q.observe(source("tail", 2), now: 1)
        q.observe(translated("tail", "请不要离开。", 2), now: 1)
        assert(!q.advance(now: 2.9) && q.text == "再见。")
        assert(q.advance(now: 3) && q.text == "请不要离开。" && q.deadline >= 6)
        q.observe(translated("tail", "obsolete", 1), now: 4)
        q.advance(now: q.deadline); assert(q.pendingCount == 0)

        q.observe(source("tail", 3), now: 10)
        q.observe(translated("tail", "后来更正的完整句子。", 3), now: 10)
        assert(q.advance(now: 11) && q.text.contains("更正"), "A late correction must not be discarded")
        let deadline = q.deadline
        q.advance(now: 12, visible: false); q.advance(now: 100, visible: false)
        assert(!q.advance(now: 102) && q.deadline == deadline + 90, "Hidden/mode-switched captions lost reading time")

        q.reset(); q.observe(source("same"), now: 0); q.observe(translated("same", "一样。"), now: 0)
        assert(q.advance(now: 0.4)); q.observe(source("same", 2), now: 1)
        q.observe(translated("same", "一样。", 2), now: 1)
        q.advance(now: 3.4); assert(q.pendingCount == 0 && q.displayedPages == 1)

        q.reset(); q.observe(source("same-revision"), now: 0)
        q.observe(translated("same-revision", "可以。"), now: 0); assert(q.advance(now: 0.4))
        q.observe(["type": "sentence_updated", "sentence_id": "same-revision", "revision": 1, "text": "changed"], now: 1)
        q.observe(translated("same-revision", "不可以。"), now: 1)
        assert(q.advance(now: 3.4) && q.text == "不可以。", "Same-revision replacement was consumed as old text")

        q.reset(); q.observe(source("failed"), now: 0); q.observe(source("after"), now: 0)
        q.observe(["type": "sentence_translation_failed", "sentence_id": "failed", "revision": 1, "display_message": "翻译失败。"], now: 0)
        q.observe(translated("after", "下一句完整译文。"), now: 0)
        q.advance(now: 1)
        assert(!q.text.contains("翻译失败") && q.text.contains("下一句"), "Operational messages must stay outside subtitles without blocking following translations")

        q.reset(); q.observe(source("multiline"), now: 0)
        q.observe(translated("multiline", "完整译文。\n\nNext line.\r\nDon't split words.\u{2028}Fin."), now: 0)
        q.advance(now: 1)
        assert(!q.text.contains(where: { $0.isNewline }))
        assert(q.text.contains("Next line.") && q.text.contains("Don't split words."))

        // Small display capacity must serialize pages instead of shrinking text
        // or consuming material that could not fit the visible caption.
        q = ReadingSubtitleQueue()
        let split: (String) -> [String] = { text in
            let characters = Array(text)
            return stride(from: 0, to: characters.count, by: 3).map {
                String(characters[$0..<min($0 + 3, characters.count)])
            }
        }
        q.configure(splitter: split, fits: { $0.filter { !$0.isWhitespace }.count <= 3 })
        q.reset() // Session reset preserves configured geometry.
        q.observe(source("geometry"), now: 0)
        let entire = "甲乙丙丁戊己庚辛壬癸"
        q.observe(translated("geometry", entire), now: 0)
        q.observe(["type": "final"], now: 0)
        var seen = "", time = 0.0
        while q.pendingCount > 0 {
            if q.advance(now: time) { seen += q.text }
            assert(q.text.count <= 3)
            time = q.deadline
        }
        assert(seen == entire && q.displayedPages == 4)
        q.configure(splitter: split, fits: { $0.filter { !$0.isWhitespace }.count <= 3 })
        q.advance(now: time)
        assert(q.text == "癸", "Resizing held final captions must not lose the final text")

        q = ReadingSubtitleQueue()
        for index in 0..<1100 {
            let id = "row-\(index)"
            q.observe(source(id), now: 0); q.observe(translated(id, "重复短句。"), now: 0)
        }
        var now = 1.0
        while q.pendingCount > 0 {
            q.advance(now: now); now = q.deadline
        }
        assert(q.displayedPages == 1100, "A backlog must not evict unread sentences")

        // Repeated ASR revisions with identical multi-page translations must
        // not restart content that is already visible or already read.
        q = ReadingSubtitleQueue()
        q.configure(splitter: split, fits: { $0.filter { !$0.isWhitespace }.count <= 3 })
        q.observe(source("unchanged-pages"), now: 0)
        q.observe(translated("unchanged-pages", entire), now: 0)
        q.observe(["type": "final"], now: 0)
        q.advance(now: 0); q.advance(now: 3)
        assert(q.text == "丁戊己")
        q.observe(source("unchanged-pages", 2), now: 4)
        q.observe(translated("unchanged-pages", entire, 2), now: 4)
        q.advance(now: 4)
        assert(q.text == "丁戊己" && q.deadline == 6 && q.displayedPages == 2)
        for t in [6.0, 9, 12] { q.advance(now: t) }
        assert(q.pendingCount == 0 && q.displayedPages == 4)
        q.observe(source("unchanged-pages", 3), now: 13)
        q.observe(translated("unchanged-pages", entire, 3), now: 13)
        q.advance(now: 13)
        assert(q.pendingCount == 0 && q.displayedPages == 4, "Identical completed revisions must not replay")

        // Twelve minutes of continuous fast speech, one screen every 3 s.
        // Old per-page serial holds accumulated minutes of visual delay here.
        q = ReadingSubtitleQueue()
        q.configure(splitter: { [$0] }, fits: { SubtitleReading.work($0) <= 8 })
        let fast = String(repeating: "实时字幕需要提前显示", count: 3)
        var shown = Set<String>()
        for index in 0..<240 {
            let id = "fast-\(index)", now = Double(index) * 3
            q.observeSpeech(text: fast, seconds: 3)
            q.observe(source(id), now: now); q.observe(translated(id, fast), now: now)
            q.advance(now: now)
            assert(q.references.contains { $0.id == id }, "Reading captions fell behind the next spoken sentence")
            assert(q.deadline >= now + 3)
            shown.formUnion(q.references.map { $0.id })
            if index % 5 == 0 {
                q.observe(source(id, 2), now: now + 1)
                q.observe(translated(id, fast, 2), now: now + 1)
                q.advance(now: now + 1)
            }
            assert(!q.advance(now: now + 2.99), "A caption flashed for less than three seconds")
        }
        q.observe(["type": "final"], now: 720); q.advance(now: 720)
        assert(shown.count == 240 && q.displayedPages == 240 && q.pendingCount == 0)

        // Bursty completed translations used to append into the current page,
        // changing wrapping after only half a second. Keep text, identity and
        // deadline fixed for a complete reading turn, including source edits.
        q = ReadingSubtitleQueue()
        q.configure(splitter: { [$0] }, fits: { $0.count <= 48 })
        var pagesSeen = Set<String>(), lastChange = -100.0, holdUntil = 0.0
        var lastText = "", lastIdentity: CompletedSubtitleState.Identity?
        for tick in 0..<3600 {
            let t = Double(tick) / 20
            if tick < 600 && tick % 10 == 0 {
                let id = "burst-\(tick / 10)"
                q.observe(source(id), now: t); q.observe(translated(id, "完整短句\(tick / 10)。"), now: t)
            }
            let changed = q.advance(now: t)
            if changed {
                assert(t >= holdUntil - 0.001 && t - lastChange >= 2.999,
                       "New data changed visible words before the screen was read")
                pagesSeen.formUnion(q.references.map { $0.id })
                lastChange = t; holdUntil = q.deadline; lastText = q.text; lastIdentity = q.identity
            } else if t < holdUntil {
                assert(q.text == lastText && q.identity == lastIdentity && q.deadline == holdUntil)
            }
        }
        assert(pagesSeen.count == 60 && q.displayedPages == 60 && q.pendingCount == 0)
        print("PASS: reading durations, ordered completion, 1100-row conservation, revisions, repeats, EOF, Unicode and pause")
    }
}
