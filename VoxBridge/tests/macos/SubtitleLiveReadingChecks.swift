import Foundation

private func pcm(_ sequence: Int, order: Int, start: Int64, end: Int64,
                 text: String, full: String? = nil, index: Int = 0, count: Int = 1,
                 id: String? = nil, revision: Int = 1) -> [String: Any] {
    var value: [String: Any] = ["seq": sequence, "sentence_id": id ?? "sentence-\(order)",
        "source_order": order, "revision": revision, "index": index, "count": count,
        "start_frame": start, "end_frame": end, "text": text]
    if let full { value["sentence_text"] = full }
    return value
}
private func wordText(_ count: Int, offset: Int = 0) -> String {
    (offset..<(offset + count)).map { "word\($0)" }.joined(separator: " ")
}
private func wordPages(_ text: String, count: Int) -> [String] {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    return stride(from: 0, to: words.count, by: count).map {
        words[$0..<min($0 + count, words.count)].joined(separator: " ")
    }
}
private func configured(_ language: String = "en", words: Int = 48) -> LiveReadingSubtitle {
    var reader = LiveReadingSubtitle()
    reader.reset(targetLanguage: language)
    reader.configure(splitter: { wordPages($0, count: words) }, fits: {
        $0.split(whereSeparator: { $0.isWhitespace }).count <= words
    })
    return reader
}
private func checkLead(_ reader: LiveReadingSubtitle, frame: Int64) {
    assert(reader.targetFrame.map { $0 <= frame + LiveReadingSubtitle.leadFrames } == true,
           "A screen jumped beyond its bounded PCM lead")
    assert(!reader.caption!.text.contains(where: { $0.isNewline }), "Display inserted a forced newline")
}

private func clocksAndGaps() {
    var reader = configured(words: 4)
    let first = pcm(1, order: 0, start: 24_000, end: 72_000, text: "First complete sentence.", full: "First complete sentence.")
    let second = pcm(2, order: 1, start: 240_000, end: 288_000, text: "Second complete sentence.", full: "Second complete sentence.")
    reader.accept([first, second])
    assert(!reader.advance(presentedFrame: nil) && reader.caption == nil)
    assert(!reader.advance(presentedFrame: 9_599))
    assert(reader.advance(presentedFrame: 9_600))
    assert(reader.caption!.text == "First complete sentence.")
    checkLead(reader, frame: 9_600)
    let frozen = reader.caption
    for _ in 0..<100 {
        reader.accept([first, second])
        assert(!reader.advance(presentedFrame: 9_600) && reader.caption == frozen)
        assert(!reader.advance(presentedFrame: nil) && reader.caption == frozen)
    }
    assert(!reader.advance(presentedFrame: 200_000) && reader.caption == frozen,
           "A silent gap advanced to an unrelated future caption")
    assert(!reader.advance(presentedFrame: 225_599))
    assert(reader.advance(presentedFrame: 225_600))
    assert(reader.caption!.text == "Second complete sentence.")
    checkLead(reader, frame: 225_600)
    let final = reader.caption
    assert(!reader.advance(presentedFrame: 900_000) && reader.caption == final,
           "Starvation erased or replayed the last caption")
    assert(!reader.advance(presentedFrame: 0), "A regressed clock replayed old speech")

    reader.reset(targetLanguage: "en")
    reader.accept([pcm(1, order: 0, start: 0, end: 24_000, text: "Initial sound.", full: "Initial sound.")])
    assert(!reader.advance(presentedFrame: -14_401))
    assert(reader.advance(presentedFrame: -14_400), "A genuine pre-output sample clock lost the initial lead")
    reader.reset(targetLanguage: "zh")
    assert(reader.caption == nil && reader.references.isEmpty && reader.targetFrame == nil)
    assert(!reader.advance(presentedFrame: 500_000), "An empty/new epoch retained previous captions")
}

private func fullSentencesAndFallback() {
    var reader = configured(words: 30)
    let full = "The complete immutable sentence stays visible while its later speech chunks arrive."
    let first = pcm(1, order: 0, start: 24_000, end: 120_000,
        text: "The complete immutable sentence stays visible", full: full, count: 2)
    reader.accept([first])
    assert(reader.advance(presentedFrame: 9_600) && reader.caption!.text == full)
    let frozen = reader.caption
    let second = pcm(2, order: 0, start: 120_000, end: 216_000,
        text: "while its later speech chunks arrive.", full: "A later correction must never replace accepted wording.", index: 1, count: 2)
    reader.accept([first, second])
    for frame: Int64 in [9_600, 24_000, 105_600, 120_000, 216_000, 400_000] {
        assert(!reader.advance(presentedFrame: frame) && reader.caption == frozen,
               "Incoming chunks reflowed or replayed a whole sentence")
    }
    assert(reader.references.count == 1 && reader.references[0].firstSequence == 1)

    // No immutable sentence metadata: each accepted chunk is its own immutable
    // turn. A later optional full sentence must not duplicate the spoken prefix.
    reader = configured(words: 30)
    reader.accept([pcm(1, order: 0, start: 0, end: 96_000, text: "Read the available first clause.", count: 2)])
    assert(reader.advance(presentedFrame: -14_400))
    let chunkCaption = reader.caption
    reader.accept([pcm(2, order: 0, start: 96_000, end: 192_000,
        text: "Then read its complete second clause.", full: "Read the available first clause. Then read its complete second clause.", index: 1, count: 2)])
    assert(!reader.advance(presentedFrame: 0) && reader.caption == chunkCaption)
    assert(reader.advance(presentedFrame: 81_600))
    assert(reader.caption!.text == "Then read its complete second clause." && reader.references[0].page == 1)
    assert(!reader.advance(presentedFrame: 300_000))

    // A paused sample clock freezes even when a future screen becomes buffered.
    reader = configured(words: 4)
    reader.accept([pcm(1, order: 0, start: 0, end: 12_000, text: "First one.", full: "First one.")])
    assert(reader.advance(presentedFrame: 0)); let paused = reader.caption
    reader.accept([pcm(2, order: 1, start: 12_000, end: 24_000, text: "Second one.", full: "Second one.")])
    assert(!reader.advance(presentedFrame: 0) && reader.caption == paused)
    assert(reader.advance(presentedFrame: 1) && reader.caption!.text == "Second one.")

    // The display may have been hidden/suspended while PCM continued. Resume
    // at current speech; independent full history owns older reading material.
    reader = configured(words: 4)
    for index in 0..<20 {
        reader.accept([pcm(index + 1, order: index, start: Int64(index) * 48_000,
            end: Int64(index + 1) * 48_000, text: "Current sentence \(index).", full: "Current sentence \(index).")])
    }
    assert(reader.advance(presentedFrame: 10 * 48_000))
    assert(reader.references[0].sourceOrder == 10, "A resumed UI replayed obsolete captions")
    assert(reader.advance(presentedFrame: 18 * 48_000))
    assert(reader.references[0].sourceOrder == 18)
}

private func groupingAndOccurrences() {
    var reader = configured(words: 12)
    let schedule = (0..<10).map { index in
        pcm(index + 1, order: index, start: Int64(index) * 12_000, end: Int64(index + 1) * 12_000,
            text: "Repeated complete phrase.", full: "Repeated complete phrase.", id: "same-id")
    }
    reader.accept(schedule)
    assert(reader.advance(presentedFrame: -14_400))
    assert(reader.references.map(\.firstSequence) == [1, 2, 3, 4])
    assert(reader.caption!.text == Array(repeating: "Repeated complete phrase.", count: 4).joined(separator: " "))
    let firstIdentity = reader.caption!.identity
    assert(!reader.advance(presentedFrame: 33_599))
    assert(reader.advance(presentedFrame: 33_600))
    assert(reader.references.map(\.firstSequence) == [5, 6, 7, 8])
    assert(reader.caption!.identity != firstIdentity, "Equal text suppressed a new source occurrence")
    assert(reader.advance(presentedFrame: 81_600))
    assert(reader.references.map(\.firstSequence) == [9, 10])
    assert(!reader.advance(presentedFrame: 300_000))

    // Fully scheduled short neighbors are grouped only within the target's
    // existing reading minimum. This window introduces no independent hold.
    for (language, expected) in [("en", 4), ("zh", 3)] {
        reader = configured(language, words: 30)
        reader.accept((0..<6).map { index in
            pcm(index + 1, order: index, start: Int64(index) * 24_000, end: Int64(index + 1) * 24_000,
                text: "Short sentence.", full: "Short sentence.")
        })
        assert(reader.advance(presentedFrame: -14_400))
        assert(reader.references.count == expected)
        assert(reader.advance(presentedFrame: Int64(expected) * 24_000 - 14_400),
               "Grouping imposed an extra minimum timer after its audio boundary")
    }

    // Once a screen is visible, later arrivals cannot append or recenter it.
    reader = configured(words: 30)
    reader.accept([schedule[0]])
    assert(reader.advance(presentedFrame: -14_400)); let immutable = reader.caption
    reader.accept(Array(schedule.prefix(5)))
    assert(!reader.advance(presentedFrame: -14_399) && reader.caption == immutable)
    assert(reader.advance(presentedFrame: -2_400))
    assert(reader.references[0].firstSequence == 2)

    // Distinct accepted corrections retain their revision and occurrence.
    reader = configured(words: 4)
    reader.accept([pcm(1, order: 0, start: 0, end: 96_000, text: "We will meet.", full: "We will meet.", id: "corrected", revision: 1),
        pcm(2, order: 1, start: 96_000, end: 192_000, text: "We will not meet.", full: "We will not meet.", id: "corrected", revision: 2)])
    assert(reader.advance(presentedFrame: -14_400)); let old = reader.caption
    assert(!reader.advance(presentedFrame: 30_000) && reader.caption == old)
    assert(reader.advance(presentedFrame: 81_600))
    assert(reader.caption!.text == "We will not meet." && reader.references[0].revision == 2)
}

private func paginationAndReflow() {
    var reader = configured(words: 5)
    let text = wordText(20)
    reader.accept([pcm(1, order: 0, start: 0, end: 480_000, text: text, full: text)])
    var seen: [String] = []
    for page in 0..<4 {
        let frame = Int64(page) * 120_000 - 14_400
        assert(reader.advance(presentedFrame: frame))
        seen.append(reader.caption!.text)
        assert(reader.references[0].page == page)
        checkLead(reader, frame: frame)
        assert(!reader.advance(presentedFrame: frame + 119_999))
    }
    assert(seen.joined(separator: " ") == text, "Physical pagination lost or replayed text")
    assert(!reader.advance(presentedFrame: 900_000))

    // Uneven real PCM chunk lengths define page anchors; no word alignment is
    // claimed. Text-work interpolation is bounded within its accepted chunk.
    reader = configured(words: 5)
    reader.accept([pcm(1, order: 0, start: 0, end: 168_000, text: wordText(7), full: text, count: 3)])
    assert(reader.advance(presentedFrame: -14_400))
    assert(reader.advance(presentedFrame: 105_600))
    assert(reader.references[0].page == 1 && abs(reader.targetFrame! - 120_000) <= 1)
    let secondPage = reader.caption
    assert(!reader.advance(presentedFrame: 200_000) && reader.caption == secondPage,
           "An unaccepted future chunk supplied a guessed page anchor")
    reader.accept([pcm(2, order: 0, start: 240_000, end: 408_000, text: wordText(7, offset: 7), full: text, index: 1, count: 3)])
    assert(reader.advance(presentedFrame: 297_600))
    assert(reader.references[0].page == 2 && abs(reader.targetFrame! - 312_000) <= 1)
    reader.accept([pcm(3, order: 0, start: 408_000, end: 552_000, text: wordText(6, offset: 14), full: text, index: 2, count: 3)])
    assert(reader.advance(presentedFrame: 417_600))
    assert(reader.references[0].page == 3 && abs(reader.targetFrame! - 432_000) <= 1)

    // Manual geometry reflows to the page currently spoken, retaining the
    // configured splitter through reset. A cosmetic update is not a timer.
    reader = configured(words: 30)
    reader.accept([pcm(1, order: 0, start: 0, end: 480_000, text: text, full: text)])
    assert(reader.advance(presentedFrame: -14_400))
    assert(!reader.advance(presentedFrame: 250_000))
    reader.configure(splitter: { wordPages($0, count: 5) }, fits: { $0.split(separator: " ").count <= 5 })
    assert(reader.advance(presentedFrame: 250_000))
    assert(reader.references[0].page == 2 && reader.caption!.text == wordText(5, offset: 10),
           "Manual reflow rewound already spoken pages")
    let resized = reader.caption
    assert(!reader.advance(presentedFrame: 250_000) && reader.caption == resized)
    reader.reset(targetLanguage: "en")
    reader.accept([pcm(1, order: 0, start: 0, end: 480_000, text: text, full: text)])
    assert(reader.advance(presentedFrame: -14_400))
    assert(reader.caption!.text == wordText(5), "Session reset lost fixed-font geometry")

    // Grapheme-safe physical pages retain every character, with natural wraps
    // and whitespace normalization performed only in the display copy.
    let unicode = "甲乙👩🏽‍💻丙丁戊己庚辛壬癸"
    reader = LiveReadingSubtitle(); reader.reset(targetLanguage: "zh")
    reader.configure(splitter: { value in
        let characters = Array(value)
        return stride(from: 0, to: characters.count, by: 3).map {
            String(characters[$0..<min($0 + 3, characters.count)])
        }
    }, fits: { $0.count <= 3 })
    reader.accept([pcm(1, order: 0, start: 0, end: 480_000, text: unicode, full: unicode)])
    var characters = ""
    for frame in stride(from: Int64(-14_400), through: 480_000, by: 1_200) {
        if reader.advance(presentedFrame: frame) { characters += reader.caption!.text }
    }
    assert(characters == unicode)

    reader = configured(words: 1)
    reader.configure(splitter: { _ in ["Lost content"] }, fits: { $0.count <= 4 })
    reader.accept([pcm(1, order: 0, start: 0, end: 48_000, text: "Keep every character.", full: "Keep every character.")])
    assert(reader.advance(presentedFrame: -14_400))
    assert(reader.caption!.text == "Keep every character.", "A lossy layout callback discarded text")
}

private func continuousFastSpeech(language: String) {
    let count = 640, duration: Int64 = 30_000 // 800 seconds: over thirteen minutes.
    let text = language == "en" ? wordText(16) : "字幕提前显示完整句子并且跟随实际播放进度。"
    var reader = LiveReadingSubtitle(); reader.reset(targetLanguage: language)
    reader.configure(splitter: { [$0] }, fits: {
        language == "en" ? $0.split(separator: " ").count <= 40 : $0.count <= 80
    })
    let schedule = (0..<count).map { index in
        pcm(index + 1, order: index, start: Int64(index) * duration, end: Int64(index + 1) * duration,
            text: text, full: text, id: "intentional-repeat")
    }
    var accepted = 0, seen = Set<Int>(), previous: SubtitlePlayback.Caption?, changes = 0
    for frame in stride(from: -LiveReadingSubtitle.leadFrames, through: Int64(count) * duration, by: 1_200) {
        while accepted < schedule.count, Int64(accepted) * duration <= frame + 240_000 { accepted += 1 }
        // This matches the player's diagnostic ring; accepted presentation plans
        // must survive later eviction from that ring.
        reader.accept(Array(schedule[max(0, accepted - 256)..<accepted]))
        if reader.advance(presentedFrame: frame) {
            checkLead(reader, frame: frame)
            assert(reader.targetFrame! >= frame, "Continuous native reading accumulated an audio backlog")
            assert(reader.caption != previous)
            seen.formUnion(reader.references.map(\.firstSequence)); previous = reader.caption; changes += 1
        }
        // Hiding an overlay does not pause this independent audio observation.
        if frame % 24_000 == 0 { assert(!reader.advance(presentedFrame: nil)) }
    }
    assert(seen == Set(1...count), "Fast \(language) PCM skipped a real occurrence")
    assert(changes > 100 && changes < count, "Short neighboring sentences did not form immutable screens")
    assert(reader.references.last!.firstSequence == count)
    assert(!reader.advance(presentedFrame: Int64(count + 100) * duration))
    print("PASS: \(language) 800 seconds, \(count) actual occurrences, \(changes) immutable native screens without cumulative drift")
}

private func retentionAndMalformedInput() {
    var reader = configured(words: 1)
    let schedule = (0..<600).map { index in
        pcm(index + 1, order: index, start: Int64(index) * 48_000, end: Int64(index + 1) * 48_000,
            text: "item\(index)", full: "item\(index)")
    }
    reader.accept(schedule)
    reader.accept(Array(schedule.suffix(256)))
    var seen = Set<Int>()
    for index in 0..<600 {
        let frame = Int64(index) * 48_000 - 14_400
        assert(reader.advance(presentedFrame: frame))
        seen.formUnion(reader.references.map(\.firstSequence))
    }
    assert(seen.count == 600, "The diagnostic ring evicted unpresented native plans")

    reader = configured(words: 30)
    var booleanSequence = schedule[0]; booleanSequence["seq"] = true
    var fractionalStart = schedule[0]; fractionalStart["start_frame"] = 0.5
    var backwards = schedule[0]; backwards["end_frame"] = 0
    var invalidCount = schedule[0]; invalidCount["count"] = 0
    reader.accept([booleanSequence, fractionalStart, backwards, invalidCount])
    assert(!reader.advance(presentedFrame: 0) && reader.caption == nil)
    var multiline = schedule[0]; multiline["sentence_text"] = "Complete\ntext\twith whitespace."
    reader.accept([multiline])
    assert(reader.advance(presentedFrame: 0))
    assert(reader.caption!.text == "Complete text with whitespace.")
}

@main struct SubtitleLiveReadingChecks {
    static func main() {
        clocksAndGaps()
        fullSentencesAndFallback()
        groupingAndOccurrences()
        paginationAndReflow()
        continuousFastSpeech(language: "en")
        continuousFastSpeech(language: "zh")
        retentionAndMalformedInput()
        print("PASS: accepted PCM lead, frozen full sentences, safe fallback, repetitions, corrections, gaps, reflow and lossless pagination")
    }
}
