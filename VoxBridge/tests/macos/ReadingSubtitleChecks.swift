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
        let pace = language == "en" ? 4.8 : 3.5
        let orientation = language == "en" ? 0.2 : 0.5
        assert(policy.wordsPerSecond == pace && policy.orientationSeconds == orientation)
        assert(abs(policy.seconds(Array(repeating: "word", count: 26).joined(separator: " ")) - (orientation + 26 / pace)) < 0.001)
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
    q.configure(splitter: { value in
        value.components(separatedBy: ". ").map { $0.hasSuffix(".") ? $0 : $0 + "." }
    }, fits: { !$0.contains(". ") })
    q.observe(source("long"), now: 0)
    q.observe(occurrence("long", first + " " + tail, Array(1...9)), now: 0)
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

private func checkSupersededPresentationOnly() {
    let absorbed: [String: Any] = ["type": "sentence_superseded", "sentence_id": "child", "revision": 1,
                                  "replacement_sentence_id": "owner", "replacement_revision": 2]
    var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { [$0] }, fits: { !$0.contains(" ") })
    q.observe(source("owner"), now: 0)
    q.observe(source("child"), now: 0)
    q.observe(translated("child", "待显示的旧子句。"), now: 0)
    q.observe(source("owner", 2), now: 0.1)
    q.observe(absorbed, now: 0.1)
    for revision in [1, 2, 99] {
        q.observe(source("child", revision), now: 0.2)
        q.observe(translated("child", "迟到子句。", revision), now: 0.2)
    }
    q.observe(translated("owner", "完整合并后的内容。", 2), now: 0.3)
    assert(q.advance(now: 1) && q.text == "完整合并后的内容。")
    assert(q.references.map { $0.id } == ["owner"])
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0, "Absorbed child left a pending row or replayed")
    q.observe(source("independent-repeat"), now: 10)
    q.observe(translated("independent-repeat", "待显示的旧子句。"), now: 10)
    assert(q.advance(now: 11) && q.references.map { $0.id } == ["independent-repeat"])

    // A visible card must finish its original reading time. Supersession only
    // cancels queued pages, and never replaces the card mid-reading.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { $0.components(separatedBy: " | ") }, fits: { !$0.contains(" ") })
    q.observe(source("owner"), now: 0)
    q.observe(translated("owner", "先读完整首句。"), now: 0)
    q.observe(source("child"), now: 0)
    q.observe(translated("child", "子句第一屏。 | 子句未读尾部。"), now: 0)
    q.advance(now: 1)
    assert(q.text == "先读完整首句。")
    assert(q.advance(now: q.deadline) && q.text == "子句第一屏。")
    let visible = q.text, identity = q.identity, until = q.deadline
    q.observe(source("owner", 2), now: until - 1)
    q.observe(translated("owner", "合并后仍保留完整尾部。", 2), now: until - 1)
    q.observe(absorbed, now: until - 1)
    assert(!q.advance(now: until - 0.001))
    assert(q.text == visible && q.identity == identity && q.deadline == until)
    assert(q.advance(now: until) && q.text == "合并后仍保留完整尾部。")
    assert(q.references.map { $0.id } == ["owner"])
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0)

    q.observe(["type": "sentence_reset"], now: 100)
    q.observe(source("child"), now: 100)
    q.observe(translated("child", "新源序列中的同名行。"), now: 100)
    assert(q.advance(now: 101) && q.references.map { $0.id } == ["child"])

    // A stale retirement cannot cancel a newer source revision.
    q = ReadingSubtitleQueue()
    q.observe(source("child", 2), now: 0)
    q.observe(absorbed, now: 0.1)
    q.observe(translated("child", "当前修订必须保留。", 2), now: 0.2)
    assert(q.advance(now: 1) && q.text == "当前修订必须保留。")
    print("PASS: presentation-only supersession, stale events, frozen visible cards and independent repeats")
}

private func checkReplacementFallbackAndEpochs() {
    func absorbed(_ child: String, by owner: String, revision: Int = 2) -> [String: Any] {
        ["type": "sentence_superseded", "sentence_id": child, "revision": 1,
         "replacement_sentence_id": owner, "replacement_revision": revision]
    }
    func failed(_ id: String, _ revision: Int) -> [String: Any] {
        ["type": "sentence_translation_failed", "sentence_id": id, "revision": revision]
    }
    var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { [$0] }, fits: { !$0.contains(" ") })
    q.observe(source("owner"), now: 0)
    q.observe(translated("owner", "旧首句完整译文。"), now: 0)
    q.observe(source("child"), now: 0)
    q.observe(translated("child", "旧子句完整译文。"), now: 0)
    q.observe(source("owner", 2), now: 0.1)
    q.observe(absorbed("child", by: "owner"), now: 0.1)
    q.observe(translated("child", "迟到旧子句不得替换。"), now: 0.2)
    assert(!q.advance(now: 1), "An unfinished owner translation must not be presented")
    q.observe(failed("owner", 2), now: 1)
    assert(q.advance(now: 1) && q.text == "旧首句完整译文。")
    assert(q.references.map { $0.revision } == [1], "Fallback must retain its actual completed revision")
    assert(q.advance(now: q.deadline) && q.text == "旧子句完整译文。", "Owner failure lost an already completed child")
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.unresolvedVersions.map { $0.id } == ["owner"],
           "Readable fallback must not claim the failed latest MT succeeded")
    q.observe(translated("owner", "重试成功的完整合并译文。", 2), now: 10)
    assert(q.advance(now: 11) && q.text == "重试成功的完整合并译文。")
    assert(q.unresolvedVersions.isEmpty, "A successful current retry left stale unresolved failure")
    q.advance(now: q.deadline); assert(q.pendingCount == 0)

    // A revision failure preserves the unread tail of an earlier complete MT,
    // without replaying its already-visible prefix or showing an error notice.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { $0.components(separatedBy: " | ") }, fits: { !$0.contains(" ") })
    q.observe(source("pages"), now: 0)
    q.observe(translated("pages", "已显示首屏。 | 完整未读尾部。"), now: 0)
    q.advance(now: 1)
    let text = q.text, identity = q.identity, deadline = q.deadline
    q.observe(source("pages", 2), now: 1.1)
    q.observe(failed("pages", 2), now: 1.2)
    q.observe(translated("pages", "迟到旧版本。"), now: 1.3)
    assert(!q.advance(now: deadline - 0.001) && q.text == text && q.identity == identity && q.deadline == deadline)
    assert(q.advance(now: deadline) && q.text == "完整未读尾部。")
    assert(q.references.map { $0.revision } == [1])
    q.advance(now: q.deadline); assert(q.pendingCount == 0 && q.displayedPages == 2)

    // A successful replacement consumes all unread fallback; late retired
    // events cannot resurrect it, even through a chain of source ownership.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    for id in ["a", "b", "c"] { q.observe(source(id), now: 0) }
    q.observe(translated("b", "旧中间句。"), now: 0)
    q.observe(translated("c", "旧最末句。"), now: 0)
    q.observe(source("b", 2), now: 0.1)
    q.observe(absorbed("c", by: "b"), now: 0.1)
    q.observe(source("a", 2), now: 0.2)
    var middle = absorbed("b", by: "a"); middle["revision"] = 2
    q.observe(middle, now: 0.2)
    q.observe(translated("a", "最终完整合并译文。", 2), now: 0.3)
    q.observe(translated("b", "迟到中间句。", 2), now: 0.4)
    q.observe(source("c", 9), now: 0.4)
    q.observe(translated("c", "迟到末句。", 9), now: 0.4)
    assert(q.advance(now: 1) && q.text == "最终完整合并译文。")
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.displayedPages == 1)

    // If no complete child MT ever existed, failure is explicitly unresolved,
    // never fabricated as successful source coverage or a caption message.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    for id in ["owner", "missing", "after"] { q.observe(source(id), now: 0) }
    q.observe(source("owner", 2), now: 0.1)
    q.observe(absorbed("missing", by: "owner"), now: 0.1)
    q.observe(failed("owner", 2), now: 0.2)
    q.observe(translated("after", "后继完整译文。"), now: 0.3)
    assert(q.advance(now: 1) && q.text == "后继完整译文。")
    assert(Set(q.unresolvedVersions.map { $0.id }) == Set(["owner", "missing"]))
    assert(q.displayedPages == 1 && q.coveredVersions.isEmpty)
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.unresolvedVersions.count == 2)

    // A ledger generation can change without sentence_reset (e.g. output
    // reconfiguration). Reused token IDs from another epoch prove no overlap.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { [$0] }, fits: { !$0.contains(" ") })
    q.observe(source("first"), now: 0)
    var first = occurrence("first", "同一段文字。", [0, 1, 2]); first["source_token_epoch"] = 1
    q.observe(first, now: 0); assert(q.advance(now: 1))
    q.observe(source("new-occurrence"), now: 1.1)
    var second = occurrence("new-occurrence", "同一段文字。", [0, 1, 2]); second["source_token_epoch"] = 2
    q.observe(second, now: 1.1)
    assert(q.advance(now: q.deadline) && q.references.map { $0.id } == ["new-occurrence"])
    assert(q.coveredVersions.isEmpty && q.displayedPages == 2)
    print("PASS: two-phase replacement, revision fallback, ownership chains, unresolved failure and token epochs")
}

private func checkCanonicalSourceRebuilds() {
    let tokens = ["alpha", "beta", "gamma", "delta"]
    func original(_ id: String, _ text: String) -> [String: Any] {
        ["type": "sentence_committed", "sentence_id": id, "revision": 1, "text": text]
    }
    func reset(_ id: String, epoch: Int, previous: [[String: Any]], old: [String] = tokens,
               replacement: [String] = tokens, complete: Bool = true) -> [String: Any] {
        ["type": "sentence_reset", "reason": "final_redecode", "caption_reset_id": id,
         "old_epoch": epoch - 1, "new_epoch": epoch, "previous_source_rows": previous,
         "previous_source_tokens": old, "canonical_replacement_tokens": replacement,
         "canonical_replacement_source": replacement.joined(separator: " "), "caption_snapshot_complete": complete]
    }
    func snapshot(_ id: String, _ text: String, order: Int, begin: Int, end: Int) -> [String: Any] {
        ["id": id, "revision": 1, "source": text, "order": order, "source_begin": begin, "source_end": end]
    }
    func rebuilt(_ id: String, text: String, resetID: String, epoch: Int, begin: Int, end: Int) -> [String: Any] {
        var event = original(id, text)
        event["caption_reset_id"] = resetID; event["new_epoch"] = epoch
        event["source_begin"] = begin; event["source_end"] = end
        return event
    }
    func result(_ id: String, _ text: String, resetID: String, epoch: Int, begin: Int, end: Int) -> [String: Any] {
        var event = translated(id, text)
        event["caption_reset_id"] = resetID; event["new_epoch"] = epoch; event["source_token_epoch"] = epoch
        event["source_begin"] = begin; event["source_end"] = end
        return event
    }
    let prior = [snapshot("old-a", "alpha beta.", order: 0, begin: 0, end: 2),
                 snapshot("old-b", "gamma delta.", order: 1, begin: 2, end: 4)]
    func prepared() -> ReadingSubtitleQueue {
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
        q.configure(splitter: { [$0] }, fits: { !$0.contains(" ") })
        q.observe(original("old-a", "alpha beta."), now: 0)
        q.observe(translated("old-a", "首句已完整翻译。"), now: 0)
        q.observe(original("old-b", "gamma delta."), now: 0)
        q.observe(translated("old-b", "末句尚未完成阅读。"), now: 0)
        q.advance(now: 1)
        return q
    }
    var q = prepared()
    let visible = q.text, identity = q.identity, deadline = q.deadline
    q.observe(reset("rebuild-1", epoch: 2, previous: prior), now: 2)
    q.observe(rebuilt("new-merged", text: "alpha beta gamma delta.", resetID: "rebuild-1", epoch: 2, begin: 0, end: 4), now: 2)
    q.observe(result("new-merged", "重译全文不能强迫旧文再次显示。", resetID: "rebuild-1", epoch: 2, begin: 0, end: 4), now: 2.1)
    // A second stop reconciliation can regroup the same canonical occurrences
    // again. It must preserve the original card and the original unread turn.
    let secondPrior = [snapshot("new-merged", "alpha beta gamma delta.", order: 0, begin: 0, end: 4)]
    var secondReset = reset("rebuild-2", epoch: 3, previous: secondPrior)
    secondReset["reason"] = "final_commit_reconcile"
    q.observe(secondReset, now: 2.2)
    q.observe(rebuilt("third-a", text: "alpha.", resetID: "rebuild-2", epoch: 3, begin: 0, end: 1), now: 2.3)
    q.observe(result("third-a", "重建新首行。", resetID: "rebuild-2", epoch: 3, begin: 0, end: 1), now: 2.4)
    q.observe(rebuilt("third-b", text: "beta gamma delta.", resetID: "rebuild-2", epoch: 3, begin: 1, end: 4), now: 2.3)
    q.observe(result("third-b", "重建新尾行。", resetID: "rebuild-2", epoch: 3, begin: 1, end: 4), now: 2.4)
    q.observe(["type": "final"], now: 2.5)
    assert(!q.advance(now: deadline - 0.001) && q.text == visible && q.identity == identity && q.deadline == deadline)
    assert(q.advance(now: deadline) && q.text == "末句尚未完成阅读。")
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.displayedPages == 2, "Exact canonical rebuilding replayed or lost an occurrence")

    // Corrected source needs a complete new reading turn, never a token-ratio
    // cut of target text. A fully successful canonical MT replaces old unread
    // fallback only after the complete final rebuild has succeeded.
    q = prepared(); let oldDeadline = q.deadline
    let corrected = ["alpha", "not", "beta", "gamma", "delta"]
    q.observe(reset("corrected", epoch: 2, previous: prior, replacement: corrected), now: 2)
    q.observe(rebuilt("correction", text: "alpha not beta gamma delta.", resetID: "corrected", epoch: 2, begin: 0, end: 5), now: 2.1)
    q.observe(result("correction", "否定修订后的完整译文及全部尾句。", resetID: "corrected", epoch: 2, begin: 0, end: 5), now: 2.2)
    assert(!q.advance(now: oldDeadline + 1), "Unfinished canonical transaction discarded fallback early")
    q.observe(["type": "final"], now: oldDeadline + 1)
    assert(q.advance(now: oldDeadline + 1) && q.text == "否定修订后的完整译文及全部尾句。")
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.unresolvedVersions.isEmpty && q.displayedPages == 2)

    // Empty/failed canonical MT restores every complete old unread turn and
    // leaves failed source coverage explicit instead of declaring full success.
    q = prepared()
    q.observe(reset("failed-rebuild", epoch: 2, previous: prior, replacement: corrected), now: 2)
    q.observe(rebuilt("failed-correction", text: "alpha not beta gamma delta.", resetID: "failed-rebuild", epoch: 2, begin: 0, end: 5), now: 2.1)
    q.observe(["type": "sentence_translation_failed", "sentence_id": "failed-correction", "revision": 1], now: 2.2)
    q.observe(["type": "final"], now: 2.3)
    assert(q.advance(now: q.deadline) && q.text == "末句尚未完成阅读。")
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.unresolvedVersions.map { $0.id } == ["failed-correction"])
    assert(q.displayedPages == 2 && q.coveredVersions.isEmpty)

    // Identical spoken words at distinct canonical positions remain two turns,
    // including when rebuilt into a single sentence with reused token IDs.
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "zh")
    q.configure(splitter: { [$0] }, fits: { !$0.contains(" ") })
    for (index, id) in ["repeat-a", "repeat-b"].enumerated() {
        q.observe(original(id, "Yes."), now: 0)
        var event = occurrence(id, "是的。", [index]); event["source_token_epoch"] = 1
        q.observe(event, now: 0)
    }
    q.advance(now: 1)
    let repeatedPrior = [snapshot("repeat-a", "Yes.", order: 0, begin: 0, end: 1),
                         snapshot("repeat-b", "Yes.", order: 1, begin: 1, end: 2)]
    q.observe(reset("repeat-reset", epoch: 2, previous: repeatedPrior, old: ["yes", "yes"], replacement: ["yes", "yes"]), now: 2)
    q.observe(rebuilt("repeat-full", text: "Yes. Yes.", resetID: "repeat-reset", epoch: 2, begin: 0, end: 2), now: 2.1)
    q.observe(result("repeat-full", "是的。 是的。", resetID: "repeat-reset", epoch: 2, begin: 0, end: 2), now: 2.2)
    q.observe(["type": "final"], now: 2.3)
    assert(q.advance(now: q.deadline) && q.references.map { $0.id } == ["repeat-b"])
    q.advance(now: q.deadline); assert(q.pendingCount == 0 && q.displayedPages == 2)
    print("PASS: frozen rebuild cards, exact canonical continuation, consecutive resets, complete corrections and failed fallback")
}

private func checkEnglishBalancedPagination() {
    func words(_ count: Int) -> String { (0..<count).map { "word\($0)" }.joined(separator: " ") + "." }
    let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
    for count in [36, 37, 39, 42, 72, 73] {
        let text = words(count), pages = SubtitleReading.englishPages(text)
        assert(pages.count == Int(ceil(Double(count) / 36)), "English pagination created an avoidable extra screen")
        assert(pages.allSatisfy { SubtitleReading.work($0) <= 12 })
        assert(compact(pages.joined()) == compact(text), "Balanced English lost or reordered characters")
        if count > 36 { assert(pages.allSatisfy { SubtitleReading.work($0) >= 6 }, "A tiny English tail charged another minimum hold") }
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
        q.configure(splitter: { [$0] }, fits: { SubtitleReading.work($0) <= 12 })
        q.observe(source("balanced"), now: 0); q.observe(translated("balanced", text), now: 0)
        q.observe(["type": "final"], now: 0)
        var shown: [String] = [], now = 0.0
        while q.pendingCount > 0 {
            if q.advance(now: now) {
                shown.append(q.text)
                let expected = SubtitleTimingPolicy.wordLanguages["en"]!.seconds(q.text)
                assert(abs(q.deadline - now - expected) < 0.001 && expected >= 3.5)
                let frozen = q.text, identity = q.identity, end = q.deadline
                q.observe(source("incoming-\(shown.count)"), now: now + 0.1)
                // A source may arrive while its translation is still pending.
                // It cannot alter the current text or its full reading budget.
                q.observe(["type": "sentence_translation_failed", "sentence_id": "incoming-\(shown.count)", "revision": 1], now: now + 0.2)
                assert(!q.advance(now: end - 0.001) && q.text == frozen && q.identity == identity && q.deadline == end)
            }
            now = q.deadline
        }
        assert(compact(shown.joined()) == compact(text) && shown.count == pages.count)
    }
    // Real font capacity can be smaller than the semantic 36-word budget.
    // Never turn a balanced 20+19 split into four 18+2/18+1 screens when three
    // direct physical pages preserve the same complete text and reading floor.
    for count in [39, 42, 72] {
        let text = words(count)
        let splitter: (String) -> [String] = { value in
            let parts = value.split(separator: " ").map(String.init)
            return stride(from: 0, to: parts.count, by: 18).map {
                parts[$0..<min($0 + 18, parts.count)].joined(separator: " ")
            }
        }
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
        q.configure(splitter: splitter, fits: { SubtitleReading.work($0) <= 6 })
        q.observe(source("physical"), now: 0); q.observe(translated("physical", text), now: 0)
        q.observe(["type": "final"], now: 0)
        var shown: [String] = [], now = 0.0
        while q.pendingCount > 0 {
            if q.advance(now: now) {
                shown.append(q.text)
                assert(SubtitleReading.work(q.text) <= 6 && q.deadline >= now + 3.5)
            }
            now = q.deadline
        }
        assert(compact(shown.joined()) == compact(text))
        assert(shown.count == Int(ceil(Double(count) / 18)), "Semantic balancing multiplied short physical pages")
        let directCost = splitter(text).reduce(0) { $0 + SubtitleTimingPolicy.wordLanguages["en"]!.seconds($1) }
        assert(now <= directCost + 0.001, "English geometry introduced unnecessary reading time")
    }
    let quoted = (0..<18).map { "before\($0)" }.joined(separator: " ")
        + " 'alpha, beta gamma' " + (0..<40).map { "after\($0)" }.joined(separator: " ") + "."
    let quotedPages = SubtitleReading.englishPages(quoted)
    assert(quotedPages.count == 2 && quotedPages.contains { $0.contains("'alpha, beta gamma'") },
           "A quoted comma split a short phrase or created another screen")
    for text in [String(repeating: "Don't split James' book, ‘quoted words’ or 1,234.56 dollars. ", count: 12),
                 String(repeating: "We paid $1,234.56 at 12:30; don't change 50% or U.S. names. ", count: 12),
                 String(repeating: "An unfinished 'quotation must keep moving without losing any text ", count: 12)] {
        let pages = SubtitleReading.englishPages(text)
        assert(compact(pages.joined()) == compact(text) && pages.allSatisfy { SubtitleReading.work($0) <= 12 })
        if text.contains("1,234.56") { assert(pages.filter { $0.contains("1,234.56") }.count > 0) }
        assert(!pages.contains { $0.hasSuffix("Don") || $0.hasPrefix("'t ") }, "A contraction was cut across a page")
    }
    // Identical completed MT stays at the existing page after a source revision;
    // balanced presentation must not restart a previously displayed prefix.
    var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
    q.configure(splitter: { [$0] }, fits: { SubtitleReading.work($0) <= 12 })
    let text = words(72), pages = SubtitleReading.englishPages(text)
    q.observe(source("revised"), now: 0); q.observe(translated("revised", text), now: 0)
    q.advance(now: 0); let firstDeadline = q.deadline
    q.observe(source("revised", 2), now: 1); q.observe(translated("revised", text, 2), now: 1)
    assert(!q.advance(now: firstDeadline - 0.001) && q.text == pages[0])
    assert(q.advance(now: firstDeadline) && q.text == pages[1])
    q.advance(now: q.deadline)
    assert(q.pendingCount == 0 && q.displayedPages == 2)
    q.observe(source("revised", 3), now: 30); q.observe(translated("revised", text, 3), now: 30)
    assert(!q.advance(now: 31) && q.pendingCount == 0 && q.displayedPages == 2)

    // A manual font change reflows the current and unread physical pages. Equal
    // MT events, both at the same and a later source revision, keep that actual
    // reflow cursor instead of switching to a newly computed page-zero layout.
    var capacity = 36
    let reflowSplitter: (String) -> [String] = { value in
        let parts = value.split(separator: " ").map(String.init)
        return stride(from: 0, to: parts.count, by: capacity).map {
            parts[$0..<min($0 + capacity, parts.count)].joined(separator: " ")
        }
    }
    q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
    q.configure(splitter: reflowSplitter, fits: { SubtitleReading.work($0) * 3 <= Double(capacity) })
    let reflowText = words(39)
    q.observe(source("font-reflow"), now: 0); q.observe(translated("font-reflow", reflowText), now: 0)
    q.observe(["type": "final"], now: 0); q.advance(now: 0)
    capacity = 18
    q.configure(splitter: reflowSplitter, fits: { SubtitleReading.work($0) * 3 <= Double(capacity) })
    assert(q.advance(now: 1))
    var reflowShown = [q.text]
    let reflowFirst = q.text, reflowIdentity = q.identity, reflowDeadline = q.deadline
    q.observe(translated("font-reflow", reflowText), now: 1.1)
    q.observe(source("font-reflow", 2), now: 1.2)
    q.observe(translated("font-reflow", reflowText, 2), now: 1.3)
    assert(!q.advance(now: reflowDeadline - 0.001) && q.text == reflowFirst
           && q.identity == reflowIdentity && q.deadline == reflowDeadline)
    var reflowNow = reflowDeadline
    while q.pendingCount > 0 {
        if q.advance(now: reflowNow) { reflowShown.append(q.text) }
        reflowNow = q.deadline
    }
    assert(compact(reflowShown.joined()) == compact(reflowText), "Equal MT replayed or lost text after font reflow")
    assert(reflowShown.count == 4 && q.displayedPages == 5)
    q.observe(source("font-reflow", 3), now: 40); q.observe(translated("font-reflow", reflowText, 3), now: 40)
    assert(!q.advance(now: 41) && q.pendingCount == 0 && q.displayedPages == 5)

    // English-only routing leaves the legacy splitter and every other target
    // language's source grouping and reading policy unchanged.
    let legacy = SubtitleReading.pages(words(39), budget: 12)
    assert(legacy.map { Int(SubtitleReading.work($0) * 3) } == [35, 4])
    for language in ["zh", "ja", "fr", "es", "it", "pt", "hi"] {
        var other = ReadingSubtitleQueue(); other.reset(targetLanguage: language)
        other.configure(splitter: { [$0] }, fits: { SubtitleReading.work($0) <= 12 })
        other.observe(source("unchanged"), now: 0); other.observe(translated("unchanged", words(39)), now: 0)
        other.observe(["type": "final"], now: 0)
        other.advance(now: 0)
        let budget = SubtitleTimingPolicy.characterLanguages[language]?.screenWorkLimit ?? 12
        assert(other.text == SubtitleReading.pages(words(39), budget: budget).first)
    }
    print("PASS: English complete-word balanced pages, short tails, quotations/numbers, frozen screens and identical revision progress")
}

private func checkEnglishPendingFontReflow() {
    let original = (0..<39).map { "word\($0)" }.joined(separator: " ") + "."
    let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
    func drain(_ queue: inout ReadingSubtitleQueue, now initial: Double, capacity: Int) -> [String] {
        var shown: [String] = [], now = initial
        for _ in 0..<20 {
            if queue.advance(now: now) {
                shown.append(queue.text)
                assert(queue.text.split(separator: " ").count <= capacity, "A restored English page no longer fits the selected font")
                let minimum = SubtitleTimingPolicy.wordLanguages[queue.targetLanguage]?.minimumSeconds ?? 3
                assert(queue.deadline >= now + minimum)
            } else { assert(queue.pendingCount == 0, "Pending font reflow left an unrenderable unread page") }
            if queue.pendingCount == 0 { break }
            now = queue.deadline
        }
        assert(queue.pendingCount == 0)
        return shown
    }
    for outcome in ["same", "failed", "corrected", "same-revision", "references", "double-revision"] {
        var capacity = 36
        let splitter: (String) -> [String] = { value in
            let words = value.split(separator: " ").map(String.init)
            return stride(from: 0, to: words.count, by: capacity).map {
                words[$0..<min($0 + capacity, words.count)].joined(separator: " ")
            }
        }
        let id = "pending-font-\(outcome)"
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: "en")
        q.configure(splitter: splitter, fits: { $0.split(separator: " ").count <= capacity })
        q.observe(source(id), now: 0); q.observe(translated(id, original), now: 0)
        q.observe(["type": "final"], now: 0); assert(q.advance(now: 0))
        let oldText = q.text, oldIdentity = q.identity, oldDeadline = q.deadline
        var revision = 2, eventNow = 1.1
        if outcome == "same-revision" {
            revision = 1
            q.observe(["type": "sentence_updated", "sentence_id": id, "revision": revision, "text": "changed source"], now: 1)
        } else { q.observe(source(id, revision), now: 1) }
        assert(!q.advance(now: 1.01) && q.text == oldText && q.identity == oldIdentity && q.deadline == oldDeadline)
        if outcome == "references" {
            // Expired cards leave the currently visible reference available for
            // manual reflow while the next source revision still awaits MT.
            assert(!q.advance(now: oldDeadline)); eventNow = oldDeadline + 0.1
        }
        capacity = 18
        q.configure(splitter: splitter, fits: { $0.split(separator: " ").count <= capacity })
        assert(!q.advance(now: eventNow - 0.01) && q.text == oldText && q.identity == oldIdentity,
               "Font reflow displayed a source whose MT has not completed")
        if outcome == "double-revision" {
            revision = 3
            q.observe(source(id, revision), now: eventNow)
            q.observe(translated(id, "Late stale translation.", 2), now: eventNow)
            assert(!q.advance(now: eventNow) && q.text == oldText)
        }
        let expected = outcome == "corrected" ? "We will not meet on the 15th. " + original : original
        if outcome == "failed" {
            q.observe(["type": "sentence_translation_failed", "sentence_id": id, "revision": revision], now: eventNow)
            assert(q.unresolvedVersions.count == 1 && q.unresolvedVersions[0].revision == revision)
        } else { q.observe(translated(id, expected, revision), now: eventNow) }
        let shown = drain(&q, now: eventNow + 0.1, capacity: capacity)
        assert(compact(shown.joined()) == compact(expected), "Pending font reflow lost, reordered or replayed completed text")
        if outcome != "corrected" { assert(shown.count == 4 && q.displayedPages == 5) }
        let count = q.displayedPages
        // Even a retry after failure must preserve the now-read actual pages.
        q.observe(translated(id, expected, revision), now: 100)
        assert(q.unresolvedVersions.isEmpty && !q.advance(now: 101) && q.displayedPages == count)
    }

    // Preserve the existing pending-font behavior outside English. The same
    // complete MT follows each target's original semantic and physical pages.
    for language in ["zh", "ja", "fr", "es", "it", "pt", "hi"] {
        var capacity = 36
        let splitter: (String) -> [String] = { value in
            let words = value.split(separator: " ").map(String.init)
            return stride(from: 0, to: words.count, by: capacity).map {
                words[$0..<min($0 + capacity, words.count)].joined(separator: " ")
            }
        }
        var q = ReadingSubtitleQueue(); q.reset(targetLanguage: language)
        q.configure(splitter: splitter, fits: { $0.split(separator: " ").count <= capacity })
        q.observe(source("other-pending"), now: 0); q.observe(translated("other-pending", original), now: 0)
        q.observe(["type": "final"], now: 0); q.advance(now: 0)
        q.observe(source("other-pending", 2), now: 1)
        capacity = 18
        q.configure(splitter: splitter, fits: { $0.split(separator: " ").count <= capacity })
        q.observe(translated("other-pending", original, 2), now: 1.1)
        let shown = drain(&q, now: 1.2, capacity: capacity)
        let expectedCounts = ["zh", "ja"].contains(language) ? [18, 11, 10] : [18, 17, 4]
        assert(shown.map { $0.split(separator: " ").count } == expectedCounts && q.displayedPages == 4)
        assert(compact(shown.joined()) == compact(original))
    }
    print("PASS: pending English MT font reflow, complete corrections, failed fallback, stale revisions and other-language preservation")
}
@main struct ReadingSubtitleChecks {
    static func main() {
        checkSupersededPresentationOnly()
        checkReplacementFallbackAndEpochs()
        checkCanonicalSourceRebuilds()
        checkEnglishBalancedPagination()
        checkEnglishPendingFontReflow()
        let migrated = try! JSONDecoder().decode(SubtitlePreferences.self, from: Data(#"{"fontSize":42,"backgroundEnabled":true}"#.utf8))
        assert(migrated.mode == .reading && migrated.fontSize == 42 && migrated.backgroundEnabled)
        var saved = migrated; saved.mode = .playback
        assert(try! JSONDecoder().decode(SubtitlePreferences.self, from: JSONEncoder().encode(saved)).mode == .playback)
        assert(SubtitleReading.seconds("谢谢。") == 3)
        assert(abs(SubtitleReading.seconds(String(repeating: "字", count: 30)) - 5 / 1.35) < 0.001)
        assert(abs(SubtitleReading.seconds("one two three four five six seven eight nine ten eleven twelve fifteen fourteen fifteen") - 5 / 1.35) < 0.001)
        assert(SubtitleReading.work("你好 don't worry") == 1)
        // Chinese holds use a fixed reading budget, independent of speech.
        // Pure Han screens contain at most 60 characters, with no lost tail.
        for count in [12, 24, 25, 40, 60, 72] {
            let text = String(repeating: "字", count: count)
            for fastFeedback in [false, true] {
                var chinese = ReadingSubtitleQueue(); chinese.reset(targetLanguage: "zh")
                chinese.observe(["type": "started"], now: 0)
                assert(chinese.targetLanguage == "zh")
                if fastFeedback { chinese.observeSpeech(text: text, seconds: 0.6) }
                chinese.observe(source("long"), now: 0)
                chinese.observe(translated("long", text), now: 0)
                assert(chinese.advance(now: 1))
                let firstText = chinese.text, held = chinese.deadline, identity = chinese.identity
                assert(firstText.count == min(count, 60))
                let expected = SubtitleReading.seconds(firstText)
                    + SubtitleReading.additionalSeconds(firstText, targetLanguage: "zh")
                assert(abs(held - 1 - expected) < 0.001)
                chinese.observe(source("next"), now: 1.1)
                chinese.observe(translated("next", "下一句。"), now: 1.1)
                chinese.observeSpeech(text: text, seconds: 0.6)
                assert(!chinese.advance(now: held - 0.001) && chinese.text == firstText
                       && chinese.identity == identity && chinese.deadline == held)
                assert(chinese.advance(now: held))
                let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
                assert(compact(firstText + chinese.text) == text + "下一句。")
                assert(chinese.deadline - held >= 3)
                chinese.advance(now: chinese.deadline)
                assert(chinese.pendingCount == 0 && chinese.displayedPages == (count > 60 ? 3 : 2))
            }
        }
        // Two short rows share a screen's minimum hold. A third that would
        // exceed its reading budget remains a complete subsequent turn.
        let dense = String(repeating: "字", count: 20)
        for language in ["zh", "ja"] {
            var grouped = ReadingSubtitleQueue(); grouped.reset(targetLanguage: language)
            grouped.observeSpeech(text: dense, seconds: 0.6)
            for id in ["a", "b", "c", "d"] {
                grouped.observe(source(id), now: 0); grouped.observe(translated(id, dense), now: 0)
            }
            assert(grouped.advance(now: 1))
            assert(grouped.references.count == 3)
            assert(abs(grouped.deadline - 1 - (60.0 / 6 / 1.35 + 1.5)) < 0.001)
            assert(grouped.advance(now: grouped.deadline) && grouped.references.map { $0.id } == ["d"])
            grouped.advance(now: grouped.deadline)
            assert(grouped.pendingCount == 0 && grouped.displayedPages == 4)
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

        // Twelve minutes of 24-character Chinese turns at a sustainable 3 s.
        // Short completed turns must not accumulate artificial display delay.
        q = ReadingSubtitleQueue()
        q.configure(splitter: { [$0] }, fits: { SubtitleReading.work($0) <= 8 })
        q.reset(targetLanguage: "zh")
        let fast = String(repeating: "实时字幕需要提前", count: 3)
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
