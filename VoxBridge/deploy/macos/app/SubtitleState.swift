import Foundation

/// Display-only whitespace normalization; never changes translation or speech.
enum SubtitlePresentation {
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func joined(_ parts: [String]) -> String {
        parts.map(singleLine).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Reading presentation only. It neither acknowledges nor schedules speech.
enum SubtitleReading {
    static func isIdeographic(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value)
                || (0xac00...0xd7af).contains($0.value) || (0x20000...0x3134f).contains($0.value)
        }
    }
    static func work(_ text: String) -> Double {
        var cjk = 0, words = 0, inWord = false
        for character in text {
            if isIdeographic(character) { cjk += 1; inWord = false }
            else if character.unicodeScalars.contains(where: { CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0) }) {
                if !inWord { words += 1 }; inWord = true
            } else if character != "'" && character != "’",
                      !character.unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0)
                          || $0.value == 0x200c || $0.value == 0x200d }) { inWord = false }
        }
        return Double(cjk) / 6 + Double(words) / 3
    }
    static func seconds(_ text: String, rate: Double = 1.35) -> Double { max(3, work(text) / rate) }

    /// A small display-only allowance for dense character-based screens. Apply once
    /// to the entire screen, after its shared minimum and paced reading time.
    static func additionalSeconds(_ text: String, targetLanguage: String) -> Double {
        guard let policy = SubtitleTimingPolicy.characterLanguages[targetLanguage] else { return 0 }
        let characters = text.filter { character in
            if policy.countKana, character.unicodeScalars.contains(where: {
                (0x3040...0x30ff).contains($0.value)
            }) { return true }
            return character.unicodeScalars.contains {
                (0x3400...0x9fff).contains($0.value) || (0x20000...0x3134f).contains($0.value)
            }
        }.count
        return min(policy.maximumExtra, max(0, Double(characters - policy.denseThreshold)) * policy.extraPerCharacter)
    }

    /// Preserve every character; prefer clause boundaries, never apostrophes.
    static func pages(_ text: String, budget: Double = 6) -> [String] {
        var rest = SubtitlePresentation.singleLine(text), result: [String] = []
        while work(rest) > budget {
            var end = rest.startIndex, preferred: String.Index?, space: String.Index?
            while end < rest.endIndex {
                let c = rest[end], next = rest.index(after: end)
                let portion = String(rest[..<next])
                if c.isWhitespace { space = next }
                let decimal = end > rest.startIndex && next < rest.endIndex
                    && rest[rest.index(before: end)].isNumber && rest[next].isNumber
                if "，,。.!?！？;；:：।॥".contains(c), !decimal, work(portion) >= budget / 2 { preferred = next }
                end = next
                if work(portion) >= budget { break }
            }
            if let preferred { end = preferred }
            else if let space, work(String(rest[..<space])) >= budget / 2 { end = space }
            else {
                // Do not split a Latin/Indic word at a layout budget.
                while end < rest.endIndex, rest[end].isLetter,
                      !rest[end].unicodeScalars.contains(where: { (0x3040...0x9fff).contains($0.value) }) {
                    end = rest.index(after: end)
                }
            }
            guard end > rest.startIndex else { break }
            let page = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            rest = String(rest[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !rest.isEmpty { result.append(rest) }
        return result
    }
}

/// Target-language defaults are independent entries so later tuning one locale
/// cannot silently alter another. Unknown/legacy callers retain their old clock.
struct SubtitleTimingPolicy {
    struct CharacterPolicy {
        let minimumSeconds: Double
        let denseThreshold: Int
        let extraPerCharacter: Double
        let maximumExtra: Double
        let countKana: Bool
    }
    static let characterLanguages: [String: CharacterPolicy] = [
        "zh": .init(minimumSeconds: 3, denseThreshold: 24, extraPerCharacter: 0.05, maximumExtra: 1.5, countKana: false),
        "ja": .init(minimumSeconds: 3, denseThreshold: 24, extraPerCharacter: 0.05, maximumExtra: 1.5, countKana: true)
    ]
    let wordsPerSecond: Double
    let minimumSeconds: Double
    let orientationSeconds: Double
    let screenWorkLimit: Double
    static let wordLanguages: [String: SubtitleTimingPolicy] = [
        "en": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12),
        "fr": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12),
        "es": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12),
        "it": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12),
        "pt": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12),
        "hi": .init(wordsPerSecond: 3.5, minimumSeconds: 3.5, orientationSeconds: 0.5, screenWorkLimit: 12)
    ]
    func seconds(_ text: String) -> Double {
        // Mixed Han/kana text also consumes reading time; it is never one word.
        max(minimumSeconds, orientationSeconds + SubtitleReading.work(text) * 3 / wordsPerSecond)
    }
}

struct ReadingSubtitleQueue {
    private struct Row {
        let id: String
        var revision: Int
        var source: String
        var pages: [String]?
        var readyAt: Double = 0
        var nextPage = 0
        var previousPages: [String]?
        var previousNextPage = 0
        var sourceTokens: [Int]?
        var translation = ""
    }
    private struct Coverage { let id: String; let tokens: [Int]; let text: String }
    private struct Part { let id: String; var revision: Int; let page: Int; let text: String }
    private struct Card { var parts: [Part]; let text: String; var readingEnd: Double; var deadline: Double }
    private var rows: [Row] = []
    private var supersededIDs: Set<String> = []
    private var cards: [Card] = []
    private var serial = 0
    private var pausedAt: Double?
    private var splitToFit: (String) -> [String] = { [$0] }
    private var fits: (String) -> Bool = { _ in true }
    private var speechSamples: [(work: Double, seconds: Double)] = []
    private var displayedCoverage: [Coverage] = []
    private(set) var coveredVersions: [(id: String, revision: Int, coveredBy: String)] = []
    private var timing: SubtitleTimingPolicy? { SubtitleTimingPolicy.wordLanguages[targetLanguage] }
    private(set) var targetLanguage = ""
    private(set) var readingRate = 1.35
    private(set) var text = ""
    private(set) var identity: CompletedSubtitleState.Identity?
    private(set) var deadline: Double = 0
    private(set) var displayedPages = 0
    private(set) var finished = false
    private(set) var references: [(id: String, revision: Int, page: Int)] = []
    var pendingCount: Int { rows.filter { $0.pages == nil || $0.nextPage < $0.pages!.count }.count + cards.count }

    private static func tokens(_ value: Any?) -> [Int]? {
        guard let values = value as? [NSNumber], !values.isEmpty, values.count <= 8192,
              values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID()
                  && $0.doubleValue >= 0 && $0.doubleValue == Double($0.intValue) }) else { return nil }
        return values.map { $0.intValue }
    }
    private static func covers(_ tokens: [Int], with known: [Int]) -> Bool {
        guard !tokens.isEmpty, tokens.count <= known.count else { return false }
        return (0...(known.count - tokens.count)).contains { start in
            known[start..<(start + tokens.count)].elementsEqual(tokens)
        }
    }
    private static func containsTranslation(_ text: String, in known: String) -> Bool {
        guard !text.isEmpty, let range = known.range(of: text) else { return false }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        return (range.lowerBound == known.startIndex || !isWord(known[known.index(before: range.lowerBound)]))
            && (range.upperBound == known.endIndex || !isWord(known[range.upperBound]))
    }
    private func coverage(for row: Row) -> Coverage? {
        guard let tokens = row.sourceTokens, !row.translation.isEmpty else { return nil }
        return Coverage(id: row.id, tokens: tokens, text: row.translation)
    }
    private func covering(_ row: Row, in known: [Coverage]) -> Coverage? {
        guard let tokens = row.sourceTokens else { return nil }
        return known.last { prior in
            guard Self.covers(tokens, with: prior.tokens) else { return false }
            // A changed translation of the same complete occurrence is a
            // correction even when it happens to be a substring of the old one.
            if prior.id == row.id || prior.tokens == tokens { return row.translation == prior.text }
            return Self.containsTranslation(row.translation, in: prior.text)
        }
    }

    /// Read-only feedback from accepted complete speech units. Never delays or
    /// changes audio; the visual clock keeps a small lead over measured speech.
    mutating func observeSpeech(text: String, seconds: Double) {
        guard timing == nil else { return }
        let work = SubtitleReading.work(text)
        guard seconds.isFinite, seconds >= 0.6, work >= 0.5 else { return }
        speechSamples.append((work, seconds))
        if speechSamples.count > 12 { speechSamples.removeFirst() }
        let measured = speechSamples.reduce(0) { $0 + $1.work } / speechSamples.reduce(0) { $0 + $1.seconds }
        readingRate = max(1.35, min(2.2, measured * 1.2))
    }

    mutating func reset(targetLanguage: String? = nil) {
        let splitter = splitToFit, capacity = fits
        let language = targetLanguage ?? self.targetLanguage
        self = ReadingSubtitleQueue()
        splitToFit = splitter; fits = capacity
        self.targetLanguage = language
    }

    mutating func configure(splitter: @escaping (String) -> [String], fits: @escaping (String) -> Bool) {
        splitToFit = splitter; self.fits = fits
        let reflowed = Set(cards.flatMap { $0.parts.map { $0.id } } + references.map { $0.id })
        displayedCoverage.removeAll { reflowed.contains($0.id) }
        // A manual font/display change can require smaller pages. Requeue the
        // visible parts with full reading time; never discard unread text.
        for card in cards {
            for part in card.parts {
                if let index = rows.firstIndex(where: { $0.id == part.id && $0.revision == part.revision }) {
                    rows[index].nextPage = min(rows[index].nextPage, part.page)
                }
            }
        }
        if cards.isEmpty {
            for part in references {
                if let index = rows.firstIndex(where: { $0.id == part.id && $0.revision == part.revision }) {
                    rows[index].nextPage = min(rows[index].nextPage, part.page)
                }
            }
        }
        for index in rows.indices {
            guard let pages = rows[index].pages else { continue }
            let start = rows[index].nextPage
            rows[index].pages = Array(pages.prefix(start)) + pages.dropFirst(start).flatMap(splitter)
        }
        cards.removeAll(); pausedAt = nil
    }

    mutating func observe(_ event: [String: Any], now: Double) {
        switch event["type"] as? String {
        case "started", "sentence_reset": reset()
        case "final": finished = true
        case "sentence_superseded":
            guard let id = event["sentence_id"] as? String, !id.isEmpty,
                  let revision = event["revision"] as? Int, revision >= 0,
                  let replacement = event["replacement_sentence_id"] as? String,
                  !replacement.isEmpty, replacement != id,
                  let replacementRevision = event["replacement_revision"] as? Int,
                  replacementRevision >= 0 else { return }
            if let row = rows.first(where: { $0.id == id }), row.revision != revision { return }
            supersededIDs.insert(id)
            rows.removeAll { $0.id == id }
            // Preserve an already visible card for its complete reading turn.
            // Only its remaining pages and late source/MT events are retired.
        case "sentence_translation_failed":
            // Operational notices belong in the App/monitor, never the overlay.
            guard let id = event["sentence_id"] as? String,
                  let revision = event["revision"] as? Int,
                  let index = rows.firstIndex(where: { $0.id == id && $0.revision == revision }),
                  rows[index].pages == nil else { return }
            rows[index].pages = []; rows[index].nextPage = 0
        case "sentence_committed", "sentence_updated":
            guard let id = event["sentence_id"] as? String, !id.isEmpty,
                  !supersededIDs.contains(id),
                  let revision = event["revision"] as? Int, revision >= 0,
                  let source = event["text"] as? String else { return }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                guard revision >= rows[index].revision else { return }
                if revision != rows[index].revision || source != rows[index].source {
                    let previous = rows[index]
                    rows[index] = Row(id: id, revision: revision, source: source,
                                      previousPages: previous.pages ?? previous.previousPages,
                                      previousNextPage: previous.pages == nil ? previous.previousNextPage : previous.nextPage)
                }
            } else { rows.append(Row(id: id, revision: revision, source: source)) }
        case "sentence_translation":
            guard let stable = event["is_stable"] as? NSNumber,
                  CFGetTypeID(stable) == CFBooleanGetTypeID(), stable.boolValue,
                  let id = event["sentence_id"] as? String,
                  let revision = event["revision"] as? Int,
                  let translation = event["translation"] as? String,
                  !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let index = rows.firstIndex(where: { $0.id == id && $0.revision == revision }) else { return }
            // Use the actual fixed-font capacity instead of pre-cutting every
            // 18–36 characters and charging another minimum hold per fragment.
            let fullText = SubtitlePresentation.singleLine(translation)
            rows[index].translation = fullText
            rows[index].sourceTokens = Self.tokens(event["source_token_ids"])
            var displayText = fullText
            // Trim only an exact already-displayed prefix of the same source
            // occurrence. Rephrased/corrected translations retain a full turn.
            if let tokens = rows[index].sourceTokens,
               let prior = displayedCoverage.last(where: { $0.id == id
                   && tokens.count > $0.tokens.count && tokens.starts(with: $0.tokens)
                   && fullText.count > $0.text.count && fullText.hasPrefix($0.text) }),
               prior.text.last.map({ ".!?。！？।॥".contains($0) }) == true {
                displayText = String(fullText.dropFirst(prior.text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let pages = SubtitleReading.pages(displayText, budget: 12).flatMap(splitToFit)
            if rows[index].pages == pages { return }
            let unchanged = rows[index].previousPages == pages
            rows[index].pages = pages; rows[index].nextPage = 0; rows[index].readyAt = now
            // Identical multi-page revisions preserve both visible and already
            // read progress. A source re-decode must not replay the entire row.
            if unchanged {
                rows[index].nextPage = rows[index].previousNextPage
                for card in cards.indices {
                    for part in cards[card].parts.indices where cards[card].parts[part].id == id {
                        cards[card].parts[part].revision = revision
                    }
                }
                // Keep revision bookkeeping current without changing the
                // visible page identity or restarting its reading time.
                for part in references.indices where references[part].id == id {
                    references[part].revision = revision
                }
            } else if pages.count == 1 {
                for card in cards.indices {
                    if let part = cards[card].parts.firstIndex(where: { $0.id == id && $0.text == pages[0] }) {
                        cards[card].parts[part].revision = revision; rows[index].nextPage = 1
                    }
                }
            }
            rows[index].previousPages = nil; rows[index].previousNextPage = 0
        default: break
        }
    }

    @discardableResult mutating func advance(now: Double, visible: Bool = true) -> Bool {
        if !visible { if pausedAt == nil { pausedAt = now }; return false }
        if let pausedAt {
            for index in cards.indices {
                cards[index].deadline += max(0, now - pausedAt)
                cards[index].readingEnd += max(0, now - pausedAt)
            }
            self.pausedAt = nil
        }
        // Freeze the entire visible screen, including its identity and layout.
        // Appending B to an already-visible A re-centers and rewraps A while it
        // is being read. Incoming translations/revisions stay queued until this
        // screen has had its complete reading time; never slide out its prefix.
        if let last = cards.last {
            deadline = last.deadline
            guard now >= last.deadline else { return false }
            cards.removeAll()
        }
        // Completed history is bounded; unread rows are never evicted to catch up.
        if rows.count > 500 {
            var removable = rows.count - 500
            rows.removeAll { row in
                guard removable > 0, let pages = row.pages, row.nextPage >= pages.count,
                      !cards.contains(where: { $0.parts.contains(where: { $0.id == row.id }) }) else { return false }
                removable -= 1; return true
            }
        }
        // Build a complete screen from material available at this boundary.
        // All groups assembled in this call become visible together and share
        // the minimum hold. Nothing is appended on a later timer tick.
        while cards.count < 8 {
            guard let first = rows.firstIndex(where: { $0.pages == nil || $0.nextPage < $0.pages!.count }),
                  rows[first].pages != nil else { break }
            var parts: [Part] = [], combined = ""
            var availableCoverage = displayedCoverage
            var covered: [(index: Int, by: String)] = []
            for index in first..<rows.count {
                let row = rows[index]
                guard let pages = row.pages else { break }
                if row.nextPage >= pages.count { continue }
                // Occurrence IDs come from the backend source ledger. Textual
                // similarity alone must never suppress a real repeated phrase.
                if row.nextPage == 0, let prior = covering(row, in: availableCoverage) {
                    covered.append((index, prior.id))
                    continue
                }
                // Do not put an old and a corrected version beside each other.
                if cards.contains(where: { $0.parts.contains(where: { $0.id == row.id && ($0.revision != row.revision || $0.page == row.nextPage) }) }) { break }
                let page = pages[row.nextPage]
                let candidate = SubtitlePresentation.joined([combined, page])
                if !combined.isEmpty && (SubtitleReading.work(combined) >= 8 || SubtitleReading.work(candidate) > 12) { break }
                let screen = SubtitlePresentation.joined(cards.map { $0.text } + [candidate])
                if let timing, SubtitleReading.work(screen) > timing.screenWorkLimit { break }
                if !fits(screen) { break }
                combined = candidate
                parts.append(Part(id: row.id, revision: row.revision, page: row.nextPage, text: page))
                if row.nextPage + 1 == pages.count, let known = coverage(for: row) { availableCoverage.append(known) }
                if row.nextPage + 1 < pages.count { break }
            }
            if parts.count == 1, SubtitleReading.work(combined) < 3,
               !finished, now < rows[first].readyAt + 0.4 { break }
            for item in covered {
                rows[item.index].nextPage = rows[item.index].pages!.count
                coveredVersions.append((rows[item.index].id, rows[item.index].revision, item.by))
                if coveredVersions.count > 500 { coveredVersions.removeFirst() }
            }
            if parts.isEmpty {
                if !covered.isEmpty { continue }
                break
            }
            for part in parts {
                if let index = rows.firstIndex(where: { $0.id == part.id && $0.revision == part.revision }) {
                    rows[index].nextPage = part.page + 1
                    if rows[index].nextPage == rows[index].pages?.count, let known = coverage(for: rows[index]) {
                        // Only the latest displayed version can justify coverage.
                        // A correction reverting to older wording still needs a turn.
                        displayedCoverage.removeAll { $0.id == known.id }
                        displayedCoverage.append(known)
                        if displayedCoverage.count > 500 { displayedCoverage.removeFirst() }
                    }
                }
            }
            let waiting = rows.filter { $0.pages != nil && $0.nextPage < $0.pages!.count }.count
            let rate = min(2.5, readingRate * (waiting >= 4 ? 1.15 : 1))
            let readingEnd = max(now, cards.last?.readingEnd ?? now) + SubtitleReading.work(combined) / rate
            let until = max(now + (SubtitleTimingPolicy.characterLanguages[targetLanguage]?.minimumSeconds ?? 3), readingEnd)
            cards.append(Card(parts: parts, text: combined, readingEnd: readingEnd, deadline: until))
            displayedPages += parts.count
        }
        if let last = cards.indices.last {
            if let timing {
                cards[last].deadline = now + timing.seconds(SubtitlePresentation.joined(cards.map { $0.text }))
            }
            cards[last].deadline += SubtitleReading.additionalSeconds(
                SubtitlePresentation.joined(cards.map { $0.text }), targetLanguage: targetLanguage)
        }
        deadline = cards.last?.deadline ?? now
        guard !cards.isEmpty else { return false } // Keep final text visible.
        let updated = SubtitlePresentation.joined(cards.map { $0.text })
        let refs = cards.flatMap { $0.parts.map { ($0.id, $0.revision, $0.page) } }
        let refKey = refs.map { "\($0.0):\($0.1):\($0.2)" }
        let oldKey = references.map { "\($0.id):\($0.revision):\($0.page)" }
        guard updated != text || refKey != oldKey else { return false }
        text = updated; references = refs; serial += 1
        identity = .init(sentenceID: "reading-\(serial)", revision: 1)
        return true
    }
}

struct CompletedSubtitleState {
    struct Identity: Equatable { let sentenceID: String; let revision: Int; var speechSequence: Int? = nil }
    private(set) var identity: Identity?
    private struct SourceSentence {
        var revision: Int
        var sourceText: String
        var order: UInt64
    }

    private static let metadataLimit = 300

    private(set) var text: String = ""
    private var sources: [String: SourceSentence] = [:]
    private var nextOrder: UInt64 = 0
    private var displayedSentenceID: String?
    private var latestDisplayedOrder: UInt64?

    mutating func observe(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "started", "sentence_reset":
            reset()
        case "sentence_committed", "sentence_updated":
            observeSource(event)
        case "sentence_translation":
            observeTranslation(event)
        default:
            break
        }
    }

    mutating func reset() {
        text = ""; identity = nil
        sources.removeAll(keepingCapacity: true)
        nextOrder = 0
        displayedSentenceID = nil
        latestDisplayedOrder = nil
    }

    private mutating func observeSource(_ event: [String: Any]) {
        guard let id = event["sentence_id"] as? String, !id.isEmpty,
              let revision = Self.integer(event["revision"]), revision >= 0,
              let sourceText = event["text"] as? String else { return }

        if var existing = sources[id] {
            guard revision >= existing.revision else { return }
            let changed = revision != existing.revision || sourceText != existing.sourceText
            existing.revision = revision
            existing.sourceText = sourceText
            sources[id] = existing
            if changed, displayedSentenceID == id {
                text = ""; identity = nil
            }
            return
        }

        if displayedSentenceID == id {
            text = ""; identity = nil
        }
        let order = allocateOrder()
        sources[id] = SourceSentence(revision: revision, sourceText: sourceText, order: order)
        evictOldestSourceIfNeeded()
    }

    private mutating func observeTranslation(_ event: [String: Any]) {
        guard Self.strictTrue(event["is_stable"]),
              let id = event["sentence_id"] as? String,
              let revision = Self.integer(event["revision"]),
              let translatedText = event["translation"] as? String, !translatedText.isEmpty,
              let source = sources[id], source.revision == revision else { return }
        if let latestDisplayedOrder, source.order < latestDisplayedOrder { return }

        identity = Identity(sentenceID: id, revision: revision)
        text = translatedText
        displayedSentenceID = id
        latestDisplayedOrder = source.order
    }

    private mutating func allocateOrder() -> UInt64 {
        if nextOrder == UInt64.max {
            let orderedIDs = sources.keys.sorted {
                sources[$0]!.order < sources[$1]!.order
            }
            for (index, id) in orderedIDs.enumerated() {
                sources[id]!.order = UInt64(index)
            }
            if let displayedSentenceID, let displayed = sources[displayedSentenceID] {
                latestDisplayedOrder = displayed.order
            } else {
                latestDisplayedOrder = nil
            }
            nextOrder = UInt64(orderedIDs.count)
        }
        let result = nextOrder
        nextOrder += 1
        return result
    }

    private mutating func evictOldestSourceIfNeeded() {
        guard sources.count > Self.metadataLimit,
              let oldest = sources.min(by: { $0.value.order < $1.value.order }) else { return }
        sources.removeValue(forKey: oldest.key)
    }

    private static func strictTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double,
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return number.intValue
    }
}
