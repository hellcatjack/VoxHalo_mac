import Foundation

/// A reading presentation of accepted native PCM. Its only clock is the existing
/// output sample position; it never schedules, acknowledges or changes speech.
struct LiveReadingSubtitle {
    static let leadFrames: Int64 = 14_400 // 0.6 seconds at the native 24 kHz rate.

    struct Reference: Equatable {
        let sentenceID: String
        let revision: Int
        let sourceOrder: Int
        let firstSequence: Int
        let page: Int
        let startFrame: Int64
    }
    private struct Chunk {
        let sequence: Int
        let sentenceID: String
        let revision: Int
        let order: Int
        let index: Int
        let count: Int
        let start: Int64
        let end: Int64
        let text: String
        let sentenceText: String?
    }
    private struct Page {
        let text: String
        let workStart: Double
        var start: Int64?
    }
    private struct Occurrence {
        let sentenceID: String
        let revision: Int
        let order: Int
        let firstSequence: Int
        let count: Int
        // Decided by the first accepted chunk. Later metadata cannot replace an
        // already visible chunk with a whole sentence and replay its prefix.
        let sentenceText: String?
        var chunks: [Chunk]
        var pages: [Page]
        var complete: Bool { chunks.last?.index == count - 1 }
    }
    private struct Key: Equatable {
        let firstSequence: Int
        let page: Int
    }
    private struct Target {
        let key: Key
        let occurrence: Int
        let page: Int
        let text: String
        let start: Int64
    }

    private var occurrences: [Occurrence] = []
    private var receivedSequence = 0
    private var shownThrough: Key?
    private var lastFrame: Int64?
    private var reflowPending = false
    private var splitToFit: (String) -> [String] = { [$0] }
    private var fits: (String) -> Bool = { _ in true }
    private var minimumFrames: Int64 = 84_000
    private(set) var caption: SubtitlePlayback.Caption?
    private(set) var references: [Reference] = []
    /// The first PCM anchor of the immutable screen. Grouped short sentences may
    /// be read together; the bounded lead applies to this screen's first anchor.
    private(set) var targetFrame: Int64?

    mutating func reset(targetLanguage: String) {
        let splitter = splitToFit, capacity = fits
        self = LiveReadingSubtitle()
        splitToFit = splitter; fits = capacity
        let minimum = SubtitleTimingPolicy.wordLanguages[targetLanguage]?.minimumSeconds
            ?? SubtitleTimingPolicy.characterLanguages[targetLanguage]?.minimumSeconds ?? 3
        minimumFrames = Int64((minimum * 24_000).rounded())
    }

    /// A manual font/display change may reflow the current speech position. It
    /// does not restart a reading timer or rewind through previously spoken pages.
    mutating func configure(splitter: @escaping (String) -> [String], fits: @escaping (String) -> Bool) {
        splitToFit = splitter; self.fits = fits
        for index in occurrences.indices { rebuildPages(at: index) }
        reflowPending = true
    }

    /// Call after accepting audio, before its bounded diagnostic schedule can
    /// evict old entries. Unpresented occurrences are retained independently.
    mutating func accept(_ schedule: [[String: Any]]) {
        for value in schedule {
            guard let sequence = Self.integer(value["seq"]), sequence > receivedSequence,
                  let chunk = Self.chunk(value) else { continue }
            receivedSequence = chunk.sequence
            if let index = occurrences.lastIndex(where: {
                $0.sentenceID == chunk.sentenceID && $0.revision == chunk.revision && $0.order == chunk.order
            }) {
                guard occurrences[index].count == chunk.count,
                      occurrences[index].chunks.last.map({ $0.index + 1 == chunk.index }) == true else { continue }
                occurrences[index].chunks.append(chunk)
                if occurrences[index].sentenceText != nil { resolvePages(at: index) }
                else { appendFallbackPages(chunk, at: index) }
            } else {
                // The native cursor normally starts at index zero. If a caller
                // joins a shortened diagnostic window, anchor its available PCM
                // instead of displaying an unscheduled missing sentence prefix.
                let full = chunk.index == 0 ? chunk.sentenceText : nil
                occurrences.append(Occurrence(sentenceID: chunk.sentenceID, revision: chunk.revision,
                    order: chunk.order, firstSequence: chunk.sequence, count: chunk.count,
                    sentenceText: full, chunks: [chunk], pages: []))
                rebuildPages(at: occurrences.count - 1)
            }
        }
    }

    @discardableResult mutating func advance(presentedFrame: Int64?) -> Bool {
        guard let frame = presentedFrame else { return false }
        if let previous = lastFrame, frame < previous { return false }
        // Buffering new material while a sample clock is paused cannot replace
        // its visible screen. Explicit geometry changes are the sole exception.
        if lastFrame == frame, caption != nil, !reflowPending { return false }
        lastFrame = frame
        let targets = allTargets()
        guard !targets.isEmpty else { return false }
        let threshold = frame > Int64.max - Self.leadFrames ? Int64.max : frame + Self.leadFrames
        let audible = targets.lastIndex { $0.start <= frame }
        let firstEligible = targets.firstIndex { $0.start <= threshold }
        var selected: Int
        if reflowPending || shownThrough == nil {
            guard let initial = audible ?? firstEligible else { return false }
            selected = initial
        } else if let previous = targets.firstIndex(where: { $0.key == shownThrough }) {
            let next = previous + 1
            guard next < targets.count, targets[next].start <= threshold else { return false }
            // A suspended UI resumes at current speech instead of replaying an
            // obsolete backlog. Complete translations remain in reading history.
            selected = max(next, audible ?? next)
        } else {
            guard let initial = audible ?? firstEligible else { return false }
            selected = initial
        }
        reflowPending = false
        let first = targets[selected]
        var members = [first], text = first.text
        let firstOccurrence = occurrences[first.occurrence]
        if firstOccurrence.complete, firstOccurrence.pages.count == 1 {
            let windowEnd = first.start > Int64.max - minimumFrames ? Int64.max : first.start + minimumFrames
            var next = selected + 1
            while next < targets.count {
                let candidate = targets[next], occurrence = occurrences[candidate.occurrence]
                let prior = occurrences[members.last!.occurrence]
                guard occurrence.complete, occurrence.pages.count == 1,
                      candidate.occurrence != members.last!.occurrence,
                      prior.chunks.last.map({ candidate.start <= $0.end }) == true,
                      candidate.start < windowEnd else { break }
                let combined = SubtitlePresentation.joined([text, candidate.text])
                guard fits(combined) else { break }
                text = combined; members.append(candidate); next += 1
            }
        }
        // Keep the entire card immutable after publication: later chunks or
        // neighboring sentences can only become a subsequent card.
        shownThrough = members.last!.key
        references = members.map { target in
            let occurrence = occurrences[target.occurrence]
            return Reference(sentenceID: occurrence.sentenceID, revision: occurrence.revision,
                sourceOrder: occurrence.order, firstSequence: occurrence.firstSequence,
                page: target.page, startFrame: target.start)
        }
        targetFrame = first.start
        let last = members.last!
        let identity = CompletedSubtitleState.Identity(
            sentenceID: "live:\(firstOccurrence.sentenceID):\(first.key.firstSequence):\(first.page):\(last.key.firstSequence):\(last.page)",
            revision: firstOccurrence.revision, speechSequence: firstOccurrence.firstSequence)
        let updated = SubtitlePlayback.Caption(text: text, identity: identity)
        let changed = caption != updated
        caption = updated
        // Current speech and every upcoming occurrence remain available for
        // manual reflow. Only fully passed occurrences are released.
        if first.occurrence > 0 { occurrences.removeFirst(first.occurrence) }
        return changed
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }
    private static func chunk(_ value: [String: Any]) -> Chunk? {
        guard let sequence = integer(value["seq"]), sequence > 0,
              let sentence = value["sentence_id"] as? String, !sentence.isEmpty,
              let revision = integer(value["revision"]), let order = integer(value["source_order"]),
              let index = integer(value["index"]), let count = integer(value["count"]),
              count > 0, count <= 256, index < count,
              let start = integer(value["start_frame"]), let end = integer(value["end_frame"]), end > start,
              let text = value["text"] as? String else { return nil }
        let full = (value["sentence_text"] as? String).map(SubtitlePresentation.singleLine)
        return Chunk(sequence: Int(sequence), sentenceID: sentence, revision: Int(revision), order: Int(order),
            index: Int(index), count: Int(count), start: start, end: end,
            text: SubtitlePresentation.singleLine(text), sentenceText: full?.isEmpty == false ? full : nil)
    }
    private static func measure(_ text: String) -> Double {
        let work = SubtitleReading.work(text)
        return work > 0 ? work : max(0.01, Double(text.count) / 6)
    }
    private func physicalPages(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        if fits(text) { return [text] }
        let pages = splitToFit(text).map(SubtitlePresentation.singleLine).filter { !$0.isEmpty }
        // A layout callback may omit boundary whitespace, but may never omit,
        // replace or reorder a character. Reject a lossy splitter as one page.
        var remainder = text[...]
        for page in pages {
            while remainder.first?.isWhitespace == true { remainder = remainder.dropFirst() }
            guard remainder.hasPrefix(page) else { return [text] }
            remainder = remainder.dropFirst(page.count)
        }
        guard !pages.isEmpty, remainder.allSatisfy({ $0.isWhitespace }) else { return [text] }
        return pages
    }
    private mutating func rebuildPages(at index: Int) {
        occurrences[index].pages = []
        if let text = occurrences[index].sentenceText {
            let parts = physicalPages(text), work = parts.map(Self.measure)
            let total = work.reduce(0, +)
            var prefix = 0.0
            for (part, amount) in zip(parts, work) {
                occurrences[index].pages.append(Page(text: part,
                    workStart: total > 0 ? prefix / total * Self.measure(text) : 0, start: nil))
                prefix += amount
            }
            resolvePages(at: index)
        } else {
            for chunk in occurrences[index].chunks { appendFallbackPages(chunk, at: index) }
        }
    }
    private mutating func appendFallbackPages(_ chunk: Chunk, at index: Int) {
        let parts = physicalPages(chunk.text), weights = parts.map(Self.measure)
        let total = weights.reduce(0, +)
        var prefix = 0.0
        for (part, work) in zip(parts, weights) {
            let offset = total > 0 ? Double(chunk.end - chunk.start) * prefix / total : 0
            occurrences[index].pages.append(Page(text: part, workStart: 0,
                start: chunk.start + Int64(offset.rounded(.down))))
            prefix += work
        }
    }
    private mutating func resolvePages(at index: Int) {
        let chunks = occurrences[index].chunks
        for page in occurrences[index].pages.indices where occurrences[index].pages[page].start == nil {
            let desired = occurrences[index].pages[page].workStart
            var prefix = 0.0
            for chunk in chunks {
                let work = Self.measure(chunk.text)
                // At an exact text boundary require the next chunk to be
                // scheduled. Its unknown starvation gap cannot be predicted.
                if desired < prefix + work - 0.000_001 || page == 0 {
                    let fraction = min(1, max(0, (desired - prefix) / work))
                    let offset = Int64((Double(chunk.end - chunk.start) * fraction).rounded(.down))
                    occurrences[index].pages[page].start = min(chunk.end - 1, chunk.start + offset)
                    break
                }
                prefix += work
            }
        }
    }
    private func allTargets() -> [Target] {
        occurrences.enumerated().flatMap { occurrence, value in
            value.pages.enumerated().compactMap { page, value in
                guard let start = value.start else { return nil }
                return Target(key: Key(firstSequence: occurrences[occurrence].firstSequence, page: page),
                    occurrence: occurrence, page: page, text: value.text, start: start)
            }
        }
    }
}
