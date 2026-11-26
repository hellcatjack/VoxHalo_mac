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
                let amount = work(portion)
                if amount > budget + 0.000_001 && end > rest.startIndex { break }
                if c.isWhitespace { space = next }
                let decimal = end > rest.startIndex && next < rest.endIndex
                    && rest[rest.index(before: end)].isNumber && rest[next].isNumber
                if "，,。.!?！？;；:：।॥".contains(c), !decimal, amount >= budget / 2 { preferred = next }
                end = next
            }
            if let preferred { end = preferred }
            else if let space, work(String(rest[..<space])) >= budget / 2 { end = space }
            guard end > rest.startIndex else { break }
            let page = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { result.append(page) }
            rest = String(rest[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// English display pagination only. Include the whole last word, and avoid
    /// a tiny final screen charging another minimum reading turn. The result is
    /// determined by text and capacity, never audio speed or queued material.
    static func englishPages(_ text: String, budget: Double = 12) -> [String] {
        let normalized = SubtitlePresentation.singleLine(text)
        guard !normalized.isEmpty else { return [] }
        guard budget.isFinite, budget > 0, work(normalized) > budget else { return [normalized] }
        let words = normalized.split(separator: " ").map(String.init)
        let amounts = words.map(work)
        // Mixed-script text can contain a single unspaced CJK run larger than a
        // screen. Retain the existing lossless character/word fallback for it.
        guard amounts.allSatisfy({ $0 <= budget + 0.000_001 }) else { return pages(normalized, budget: budget) }
        var prefix = [0.0]
        for amount in amounts { prefix.append(prefix.last! + amount) }
        var protected = Set<Int>(), openQuotes: [Character: Int] = [:]
        func wordCharacter(_ c: Character?) -> Bool {
            c?.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) } == true
        }
        for index in words.indices {
            let characters = Array(words[index])
            for offset in characters.indices {
                let character = characters[offset]
                guard "'’‘\"“”".contains(character) else { continue }
                let before = offset > 0 ? characters[offset - 1] : nil
                let after = offset + 1 < characters.count ? characters[offset + 1] : nil
                let key: Character = "'’‘".contains(character) ? "'" : "\""
                if key == "'", wordCharacter(before), wordCharacter(after) { continue }
                if let start = openQuotes.removeValue(forKey: key) {
                    if prefix[index + 1] - prefix[start] <= min(6, budget), start < index {
                        protected.formUnion((start + 1)...index)
                    }
                } else if !wordCharacter(before), after != nil, character != "’", character != "”" {
                    openQuotes[key] = index
                }
            }
        }
        func clauseEnd(_ word: String) -> Bool {
            var suffix = word[...]
            while let last = suffix.last, "'’\"”)]}".contains(last) { suffix = suffix.dropLast() }
            return suffix.last.map { ".!?;:,。！？；：，".contains($0) } == true
        }
        var result: [String] = [], start = 0
        while start < words.count {
            let remaining = prefix.last! - prefix[start]
            if remaining <= budget + 0.000_001 {
                result.append(words[start...].joined(separator: " ")); break
            }
            let screens = max(2, Int(ceil(remaining / budget - 0.000_001)))
            let target = remaining / Double(screens)
            let minimum = remaining - budget * Double(screens - 1)
            var candidates: [(end: Int, amount: Double)] = []
            for end in (start + 1)...words.count {
                let amount = prefix[end] - prefix[start]
                if amount > budget + 0.000_001 { break }
                candidates.append((end, amount))
            }
            // Protect short quotations when a whole-word boundary outside them
            // can retain the minimum screen count. Physical capacity still wins
            // over an atomic quote which would otherwise force an extra screen.
            let required = candidates.filter { $0.amount + 0.000_001 >= minimum }
            let eligible = required.isEmpty ? candidates : required
            let outsideQuotes = eligible.filter { !protected.contains($0.end) }
            let safe = outsideQuotes.isEmpty ? eligible : outsideQuotes
            let natural = safe.filter { !protected.contains($0.end) && clauseEnd(words[$0.end - 1])
                && abs($0.amount - target) <= max(0.5, target * 0.25) }
            let choices = natural.isEmpty ? safe : natural
            guard let selected = choices.min(by: {
                let left = abs($0.amount - target), right = abs($1.amount - target)
                return abs(left - right) < 0.000_001 ? $0.end > $1.end : left < right
            }) else { return pages(normalized, budget: budget) }
            result.append(words[start..<selected.end].joined(separator: " "))
            start = selected.end
        }
        return result
    }
}

/// Target-language defaults are independent entries so later tuning one locale
/// cannot silently alter another. Unknown/legacy callers retain their old clock.
struct SubtitleTimingPolicy {
    struct CharacterPolicy {
        let minimumSeconds: Double
        let paceFactor: Double
        let screenWorkLimit: Double
        let denseThreshold: Int
        let extraPerCharacter: Double
        let maximumExtra: Double
        let countKana: Bool
    }
    static let characterLanguages: [String: CharacterPolicy] = [
        "zh": .init(minimumSeconds: 3, paceFactor: 1.35, screenWorkLimit: 10, denseThreshold: 24, extraPerCharacter: 0.05, maximumExtra: 1.5, countKana: false),
        "ja": .init(minimumSeconds: 3, paceFactor: 1.35, screenWorkLimit: 10, denseThreshold: 24, extraPerCharacter: 0.05, maximumExtra: 1.5, countKana: true)
    ]
    let wordsPerSecond: Double
    let minimumSeconds: Double
    let orientationSeconds: Double
    let screenWorkLimit: Double
    static let wordLanguages: [String: SubtitleTimingPolicy] = [
        "en": .init(wordsPerSecond: 4.8, minimumSeconds: 3.5, orientationSeconds: 0.2, screenWorkLimit: 12),
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
    private struct CompletedVersion {
        let revision: Int
        let translation: String
        let sourceTokens: [Int]?
        let sourceTokenEpoch: String
        let pages: [String]
        let nextPage: Int
        let readyAt: Double
    }
    private struct Row {
        let id: String
        var revision: Int
        var source: String
        var pages: [String]?
        var readyAt: Double = 0
        var nextPage = 0
        var previousPages: [String]?
        var previousNextPage = 0
        var previousCompleted: CompletedVersion?
        var displayRevision: Int?
        var sourceTokens: [Int]?
        var sourceTokenEpoch = "visual:0"
        var canonicalRange: Range<Int>?
        var failedRevision: Int?
        var translation = ""
        var completed: CompletedVersion? {
            guard let pages, !pages.isEmpty, !translation.isEmpty else { return nil }
            return CompletedVersion(revision: displayRevision ?? revision, translation: translation,
                sourceTokens: sourceTokens, sourceTokenEpoch: sourceTokenEpoch,
                pages: pages, nextPage: nextPage, readyAt: readyAt)
        }
    }
    private struct Replacement { let id: String; let revision: Int }
    private struct RebuildProjection {
        let id: String
        let epoch: Int
        let tokens: [String]
        var ignoredRows: [String: Int] = [:]
    }
    private struct RebuildFallback {
        let tokens: [String]?
        let rows: [Row]
    }
    private struct Coverage { let id: String; let tokens: [Int]; let epoch: String; let text: String }
    private struct Part { let id: String; var revision: Int; let page: Int; let text: String }
    private struct Card { var parts: [Part]; let text: String; var readingEnd: Double; var deadline: Double }
    private struct DraftPage {
        let displayText: String
        let sourcePrefix: String
        let translationPrefix: String
    }
    private struct Draft {
        let text: String
        let source: String?
        let anchor: String
        var baseSource: String?
        var delta: String?
        var replacementID: String?
        var shownPages: [DraftPage] = []
        var displayPages: [String] = []
        var nextDisplayPage = 0
    }
    private struct PendingCaptionTail {
        var event: [String: Any]
        let expiresAt: Double
    }
    private let compact: Bool
    private var rows: [Row] = []
    private var supersededIDs: Set<String> = []
    /// A terminal source retirement does not discard a completed visual fallback
    /// until the replacement translation has actually completed successfully.
    private var pendingReplacements: [String: Replacement] = [:]
    private var sourceEpoch = 0
    private var rebuildProjection: RebuildProjection?
    private var rebuildFallback: RebuildFallback?
    private var cards: [Card] = []
    private var drafts: [Draft] = []
    private var shownDrafts: [String: Draft] = [:]
    private var pendingCaptionTails: [String: PendingCaptionTail] = [:]
    private var latestSourceID = ""
    private var latestDraftAnchor: String?
    private var serial = 0
    private var pausedAt: Double?
    private var splitToFit: (String) -> [String] = { [$0] }
    private var fits: (String) -> Bool = { _ in true }
    private var displayedCoverage: [Coverage] = []
    private(set) var coveredVersions: [(id: String, revision: Int, coveredBy: String)] = []
    init(compact: Bool = false) { self.compact = compact }

    private var timing: SubtitleTimingPolicy? { SubtitleTimingPolicy.wordLanguages[targetLanguage] }
    private var screenWorkLimit: Double {
        compact ? 6 : (SubtitleTimingPolicy.characterLanguages[targetLanguage]?.screenWorkLimit ?? timing?.screenWorkLimit ?? 12)
    }
    private func compactSeconds(_ text: String) -> Double {
        let work = SubtitleReading.work(text)
        let rate = timing.map { $0.wordsPerSecond / 3 }
            ?? SubtitleTimingPolicy.characterLanguages[targetLanguage]?.paceFactor ?? readingRate
        return max(2.4, work / rate + (timing?.orientationSeconds ?? 0))
            + SubtitleReading.additionalSeconds(text, targetLanguage: targetLanguage)
    }
    private func englishDisplayPages(_ text: String, budget: Double) -> [String] {
        let balanced = SubtitleReading.englishPages(text, budget: budget).flatMap(splitToFit)
            .map(SubtitlePresentation.singleLine)
        let physical = splitToFit(text).flatMap { SubtitleReading.englishPages($0, budget: budget) }
            .flatMap(splitToFit).map(SubtitlePresentation.singleLine)
        let content = text.filter { !$0.isWhitespace }
        func valid(_ pages: [String]) -> Bool {
            !pages.isEmpty && pages.allSatisfy { !$0.isEmpty && fits($0) && SubtitleReading.work($0) <= budget + 0.000_001 }
                && pages.joined().filter { !$0.isWhitespace } == content
        }
        let balancedValid = valid(balanced), physicalValid = valid(physical)
        if !balancedValid { return physicalValid ? physical : [text] }
        guard physicalValid, let timing else { return balanced }
        let balancedSeconds = balanced.reduce(0) { $0 + timing.seconds($1) }
        let physicalSeconds = physical.reduce(0) { $0 + timing.seconds($1) }
        // A large selected font may otherwise split each balanced semantic page
        // again, creating several tiny tails. Deterministic physical-first pages
        // win only when their complete reading turns cost less; ties stay stable.
        return physicalSeconds < balancedSeconds - 0.000_001 ? physical : balanced
    }

    private static func englishSuffix(of full: String, after prefix: String, preview: Bool = false) -> String? {
        guard !prefix.isEmpty else { return nil }
        if full == prefix { return "" }
        if full.hasPrefix(prefix) && (!preview || prefix.last.map({ ".,;:".contains($0) }) == true) {
            let tail = full.dropFirst(prefix.count)
            if tail.first?.isWhitespace == true { return String(tail.drop(while: \.isWhitespace)) }
        }
        // Standalone MT can end a source clause with a period that becomes a
        // comma in context. Keep exact wording and require a clause boundary.
        if preview, let end = prefix.last, ".,:…".contains(end) {
            let clause = prefix.dropLast()
            guard !clause.isEmpty, full.hasPrefix(clause) else { return nil }
            let tail = full.dropFirst(clause.count)
            if ":…".contains(end), tail.first?.isWhitespace == true {
                return String(tail.drop(while: \.isWhitespace))
            }
            if let stop = tail.first, ".,".contains(stop) {
                let rest = tail.dropFirst()
                if rest.isEmpty || rest.first?.isWhitespace == true {
                    return String(rest.drop(while: \.isWhitespace))
                }
            }
        }
        return nil
    }

    private static func sourceExtendsPreview(_ preview: String, _ source: String) -> Bool {
        let rawDraft = preview.filter { !$0.isWhitespace }
        let rawFull = source.filter { !$0.isWhitespace }
        guard !rawDraft.isEmpty else { return false }
        if rawFull.hasPrefix(rawDraft) { return true }
        let draft = captionSourceWords(preview)
        let full = captionSourceWords(source)
        if full.hasPrefix(draft) { return true }
        let punctuation = "。.,，;；:："
        let words = draft.dropLast()
        return !words.isEmpty && words.last?.isNumber != true
            && draft.last.map(punctuation.contains) == true && full.hasPrefix(words)
            && full.dropFirst(words.count).first.map(punctuation.contains) == true
    }

    private static func equalCaptionSource(_ left: String, _ right: String) -> Bool {
        func normalized(_ text: String) -> String {
            String(captionSourceWords(text).reversed()
                .drop(while: { "。.,，;；:：".contains($0) }).reversed())
        }
        let prefix = normalized(left)
        return !prefix.isEmpty && prefix == normalized(right)
    }

    private static func captionSourceWords(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: #"(?<=\p{Han})[，,](?=\p{Han})"#, with: "", options: .regularExpression)
    }

    private mutating func finishPendingCaptionTail(_ id: String, now: Double, tail: String? = nil) {
        guard var pending = pendingCaptionTails.removeValue(forKey: id) else { return }
        pending.event.removeValue(forKey: "caption_tail_expected")
        if let tail, !tail.isEmpty { pending.event["caption_tail_translation"] = tail }
        else { pending.event.removeValue(forKey: "caption_prefix") }
        observe(pending.event, now: now)
    }

    private static func englishDraftContinuation(of full: String, after prefix: String) -> String? {
        if let suffix = englishSuffix(of: full, after: prefix, preview: true) { return suffix }
        // The standalone and whole-sentence translations can choose the same
        // contrast marker in different forms. The remaining words must agree.
        for marker in [#"^(?:But,?\s+|However,\s+)"#,
                       #"^(?:One last point:\s+|The last point is that\s+)"#] {
            if let first = prefix.range(of: marker, options: .regularExpression),
               let second = full.range(of: marker, options: .regularExpression) {
                return englishSuffix(of: String(full[second.upperBound...]),
                                     after: String(prefix[first.upperBound...]), preview: true)
            }
        }
        return nil
    }

    private static func sharedEnglishClause(from preview: String, in full: String) -> (String, String)? {
        // Keep only words that match through a genuine punctuation boundary.
        // Revised claims after that point still take their own reading turn.
        for stop in preview.indices.reversed() where ",;:".contains(preview[stop]) {
            let next = preview.index(after: stop)
            guard next < preview.endIndex, preview[next].isWhitespace else { continue }
            let prefix = String(preview[..<next])
            guard SubtitleReading.work(prefix) >= 4.0 / 3.0,
                  let suffix = englishDraftContinuation(of: full, after: prefix),
                  !suffix.isEmpty, suffix.first?.isNumber != true else { continue }
            return (prefix, suffix)
        }
        return nil
    }

    private func previewPages(_ text: String) -> [String] {
        let pages = targetLanguage == "en" ? englishDisplayPages(text, budget: screenWorkLimit) : [text]
        return pages.allSatisfy { !$0.isEmpty && fits($0) && SubtitleReading.work($0) <= screenWorkLimit + 0.000_001 }
            ? pages : []
    }

    private func previewCoverage(id: String, prefix: String) -> (read: [String], waiting: [String])? {
        let shown = shownDrafts.values.first { $0.replacementID == id }
        var source = shown?.source ?? ""
        var read = shown?.shownPages.map(\.displayText) ?? []
        var waiting: [String] = []
        if Self.equalCaptionSource(source, prefix) { return (read, waiting) }
        if let shown, let page = shown.shownPages.lastIndex(where: {
            Self.equalCaptionSource($0.sourcePrefix, prefix)
        }) {
            return (Array(read.prefix(page + 1)), [])
        }
        for draft in drafts where draft.replacementID == id {
            guard let nextSource = draft.source else { return nil }
            if let base = draft.baseSource {
                guard Self.equalCaptionSource(source, base) else { return nil }
            } else if !source.isEmpty { return nil }
            let pages = draft.displayPages.isEmpty ? previewPages(draft.delta ?? draft.text) : draft.displayPages
            guard !pages.isEmpty else { return nil }
            read += pages.prefix(draft.nextDisplayPage)
            waiting += pages.dropFirst(draft.nextDisplayPage)
            source = nextSource
            if Self.equalCaptionSource(source, prefix) { return (read, waiting) }
        }
        return nil
    }
    private(set) var targetLanguage = ""
    private(set) var readingRate = 1.35
    private(set) var text = ""
    private(set) var identity: CompletedSubtitleState.Identity?
    private(set) var deadline: Double = 0
    private(set) var displayedPages = 0
    private(set) var finished = false
    private(set) var references: [(id: String, revision: Int, page: Int)] = []
    var pendingCount: Int {
        rows.filter { $0.pages == nil || $0.nextPage < $0.pages!.count }.count + cards.count
            + (rebuildFallback == nil ? 0 : 1)
    }
    /// Operational completeness is separate from visual queue exhaustion. A
    /// failed source with no complete fallback never counts as displayed text.
    var unresolvedVersions: [(id: String, revision: Int)] {
        rows.compactMap { row in
            if let revision = row.failedRevision { return (row.id, revision) }
            return row.pages?.isEmpty == true && row.translation.isEmpty ? (row.id, row.revision) : nil
        }
    }

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
        return Coverage(id: row.id, tokens: tokens, epoch: row.sourceTokenEpoch, text: row.translation)
    }
    private func covering(_ row: Row, in known: [Coverage]) -> Coverage? {
        guard let tokens = row.sourceTokens else { return nil }
        return known.last { prior in
            guard prior.epoch == row.sourceTokenEpoch, Self.covers(tokens, with: prior.tokens) else { return false }
            // A changed translation of the same complete occurrence is a
            // correction even when it happens to be a substring of the old one.
            if prior.id == row.id || prior.tokens == tokens { return row.translation == prior.text }
            return Self.containsTranslation(row.translation, in: prior.text)
        }
    }

    private mutating func restoreCompletedFallback(at index: Int) {
        guard rows[index].pages == nil else { return }
        if let prior = rows[index].previousCompleted {
            rows[index].pages = prior.pages
            rows[index].nextPage = prior.nextPage
            rows[index].displayRevision = prior.revision
            rows[index].translation = prior.translation
            rows[index].sourceTokens = prior.sourceTokens
            rows[index].sourceTokenEpoch = prior.sourceTokenEpoch
            rows[index].readyAt = prior.readyAt
        } else {
            // This row never produced a complete translation. It has no visual
            // content to recover and must not block following completed rows.
            rows[index].pages = []
            rows[index].nextPage = 0
            rows[index].failedRevision = rows[index].revision
        }
    }

    private mutating func completeReplacement(_ id: String, revision: Int) {
        var replaced = Set(pendingReplacements.compactMap { child, replacement in
            replacement.id == id && replacement.revision <= revision ? child : nil
        })
        // Ownership can be transferred more than once before MT completes. A
        // successful terminal owner covers its intermediate owners' children.
        var previousCount = -1
        while previousCount != replaced.count {
            previousCount = replaced.count
            for (child, replacement) in pendingReplacements where replaced.contains(replacement.id) {
                replaced.insert(child)
            }
        }
        guard !replaced.isEmpty else { return }
        rows.removeAll { replaced.contains($0.id) }
        for child in replaced { pendingReplacements.removeValue(forKey: child) }
        // Visible parts remain frozen for their original reading turn. Only
        // unread fallback pages are consumed by the successful replacement.
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
    private static func canonicalRange(_ event: [String: Any], limit: Int) -> Range<Int>? {
        guard let begin = nonnegativeInteger(event["source_begin"]),
              let end = nonnegativeInteger(event["source_end"]), begin < end, end <= limit else { return nil }
        return begin..<end
    }
    private static func partitions(_ ranges: [Range<Int>], tokenCount: Int) -> Bool {
        var cursor = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == cursor, range.upperBound <= tokenCount else { return false }
            cursor = range.upperBound
        }
        return cursor == tokenCount && tokenCount > 0
    }
    private mutating func observeSourceRebuild(_ event: [String: Any]) {
        sourceEpoch += 1
        finished = false
        let priorProjection = rebuildProjection
        rebuildProjection = nil
        supersededIDs.removeAll(); pendingReplacements.removeAll()
        // A second rebuild before final does not discard the first transaction's
        // recoverable, completed old translations.
        var fallbackRows = rebuildFallback?.rows ?? rows
        if rebuildFallback != nil {
            let known = Set(fallbackRows.map { $0.id })
            // A second canonical correction must not erase complete results
            // which arrived while the first rebuild was still being staged.
            fallbackRows.append(contentsOf: rows.filter { !known.contains($0.id) })
        }
        let complete = (event["caption_snapshot_complete"] as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } == true
        let previousTokens = event["previous_source_tokens"] as? [String]
        let canonicalTokens = event["canonical_replacement_tokens"] as? [String]
        let snapshot = event["previous_source_rows"] as? [[String: Any]]
        var mappedRows = rows
        if priorProjection?.tokens != previousTokens {
            for index in mappedRows.indices { mappedRows[index].canonicalRange = nil }
        }
        var snapshotRanges: [Range<Int>] = [], snapshotIDs = Set<String>(), priorOrder = -1
        let oldEpoch = Self.nonnegativeInteger(event["old_epoch"])
        let newEpoch = Self.nonnegativeInteger(event["new_epoch"])
        var snapshotValid = complete && previousTokens?.isEmpty == false
            && oldEpoch != nil && newEpoch != nil && newEpoch! > oldEpoch!
            && previousTokens?.allSatisfy({ !$0.isEmpty }) == true
            && canonicalTokens?.allSatisfy({ !$0.isEmpty }) == true
        if let previousTokens, let snapshot, !snapshot.isEmpty {
            for source in snapshot {
                guard let id = source["id"] as? String, !id.isEmpty, snapshotIDs.insert(id).inserted,
                      let revision = Self.nonnegativeInteger(source["revision"]),
                      let order = Self.nonnegativeInteger(source["order"]), order > priorOrder,
                      let text = source["source"] as? String,
                      let range = Self.canonicalRange(source, limit: previousTokens.count) else {
                    snapshotValid = false; break
                }
                priorOrder = order; snapshotRanges.append(range)
                if let index = mappedRows.firstIndex(where: { $0.id == id }),
                   mappedRows[index].revision == revision, mappedRows[index].source == text,
                   mappedRows[index].completed?.revision == revision, mappedRows[index].failedRevision == nil {
                    mappedRows[index].canonicalRange = range
                } else if priorProjection?.tokens != previousTokens { snapshotValid = false }
            }
            snapshotValid = snapshotValid && Self.partitions(snapshotRanges, tokenCount: previousTokens.count)
        } else { snapshotValid = false }
        let completedRanges = mappedRows.compactMap { row -> Range<Int>? in
            guard row.completed != nil else { return nil }
            return row.canonicalRange
        }
        let unreadMapped = mappedRows.allSatisfy { row in
            guard let pages = row.pages, row.nextPage < pages.count else { return true }
            return row.canonicalRange != nil
        }
        if snapshotValid, let previousTokens, let canonicalTokens, previousTokens == canonicalTokens,
           unreadMapped,
           Self.partitions(completedRanges, tokenCount: canonicalTokens.count),
           let id = event["caption_reset_id"] as? String, !id.isEmpty,
           let epoch = Self.nonnegativeInteger(event["new_epoch"]) {
            // Identical source occurrences already have complete translations.
            // Keep their exact old reading turns, even when new source grouping
            // crosses the already-read/unread boundary. Never slice target text
            // in proportion to source tokens.
            rows = mappedRows
            rebuildFallback = nil
            rebuildProjection = RebuildProjection(id: id, epoch: epoch, tokens: canonicalTokens)
            return
        }
        // Corrected or unprovable full re-decodes form a visual transaction.
        // The current immutable card keeps its time. Complete old unread turns
        // are held until final establishes whether the rebuilt MT fully succeeds.
        rebuildFallback = RebuildFallback(tokens: canonicalTokens, rows: fallbackRows)
        rows = []
    }
    private mutating func finishSourceRebuild() {
        guard let fallback = rebuildFallback else { return }
        // The final event closes this source transaction. A result which never
        // completed remains explicit unresolved coverage, not an eternal head
        // which prevents the retained complete fallback from being read.
        for index in rows.indices where rows[index].pages == nil {
            rows[index].failedRevision = rows[index].revision
            restoreCompletedFallback(at: index)
        }
        let ranges = rows.compactMap { $0.canonicalRange }
        let fullyTranslated = !rows.isEmpty && rows.allSatisfy {
            $0.completed?.revision == $0.revision
        }
        let completeRange = fallback.tokens.map {
            ranges.count == rows.count && Self.partitions(ranges, tokenCount: $0.count)
        } == true
        if !fullyTranslated || !completeRange {
            var recovered: [Row] = []
            for var row in fallback.rows {
                if row.pages == nil, let prior = row.previousCompleted {
                    row.pages = prior.pages; row.nextPage = prior.nextPage
                    row.displayRevision = prior.revision; row.translation = prior.translation
                    row.sourceTokens = prior.sourceTokens; row.sourceTokenEpoch = prior.sourceTokenEpoch
                    row.readyAt = prior.readyAt
                } else if row.pages == nil {
                    row.pages = []; row.nextPage = 0; row.failedRevision = row.revision
                }
                if row.failedRevision != nil || row.pages?.isEmpty == true || row.nextPage < (row.pages?.count ?? 0) { recovered.append(row) }
            }
            // Unprovable alignment retains all known complete unread content.
            // Successful rebuilt rows are then complete corrections, which may
            // repeat context; ambiguous overlap is never silently cut away.
            rows = recovered + rows
        }
        rebuildFallback = nil
    }
    private mutating func suppressRebuiltSource(_ event: [String: Any], id: String, revision: Int) -> Bool {
        guard var projection = rebuildProjection,
              event["caption_reset_id"] as? String == projection.id,
              Self.nonnegativeInteger(event["new_epoch"] ?? event["source_token_epoch"]) == projection.epoch,
              Self.canonicalRange(event, limit: projection.tokens.count) != nil else { return false }
        projection.ignoredRows[id] = revision
        rebuildProjection = projection
        return true
    }

    /// Retained as a presentation-only compatibility hook. Native speech speed
    /// cannot shorten the independent target-language reading budget.
    mutating func observeSpeech(text: String, seconds: Double) {
        _ = text; _ = seconds
    }

    mutating func reset(targetLanguage: String? = nil) {
        let splitter = splitToFit, capacity = fits
        let language = targetLanguage ?? self.targetLanguage
        self = ReadingSubtitleQueue(compact: compact)
        splitToFit = splitter; fits = capacity
        self.targetLanguage = language
    }

    private mutating func rewindReflowPart(id: String, revision: Int, page: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        if targetLanguage == "en", rows[index].pages == nil,
           let prior = rows[index].previousCompleted, prior.revision == revision {
            // A newer source may still be awaiting MT. Its visible old part
            // belongs to the completed fallback, including same-revision edits.
            let next = min(prior.nextPage, page)
            rows[index].previousCompleted = CompletedVersion(revision: prior.revision, translation: prior.translation,
                sourceTokens: prior.sourceTokens, sourceTokenEpoch: prior.sourceTokenEpoch,
                pages: prior.pages, nextPage: next, readyAt: prior.readyAt)
            rows[index].previousNextPage = next
        } else if (rows[index].displayRevision ?? rows[index].revision) == revision {
            rows[index].nextPage = min(rows[index].nextPage, page)
        }
    }

    mutating func configure(splitter: @escaping (String) -> [String], fits: @escaping (String) -> Bool) {
        splitToFit = splitter; self.fits = fits
        let reflowed = Set(cards.flatMap { $0.parts.map { $0.id } } + references.map { $0.id })
        displayedCoverage.removeAll { reflowed.contains($0.id) }
        // A manual font/display change can require smaller pages. Requeue the
        // visible parts with full reading time; never discard unread text.
        for card in cards {
            for part in card.parts {
                rewindReflowPart(id: part.id, revision: part.revision, page: part.page)
            }
        }
        if cards.isEmpty {
            for part in references {
                rewindReflowPart(id: part.id, revision: part.revision, page: part.page)
            }
        }
        for index in rows.indices {
            if let pages = rows[index].pages {
                let start = rows[index].nextPage
                rows[index].pages = Array(pages.prefix(start)) + pages.dropFirst(start).flatMap(splitter)
            } else if targetLanguage == "en", let prior = rows[index].previousCompleted {
                // Reflow the actual completed cursor without making unfinished
                // MT visible. Its success/failure will recover these safe pages.
                let start = prior.nextPage
                let pages = Array(prior.pages.prefix(start)) + prior.pages.dropFirst(start).flatMap(splitter)
                rows[index].previousCompleted = CompletedVersion(revision: prior.revision, translation: prior.translation,
                    sourceTokens: prior.sourceTokens, sourceTokenEpoch: prior.sourceTokenEpoch,
                    pages: pages, nextPage: start, readyAt: prior.readyAt)
                rows[index].previousPages = pages; rows[index].previousNextPage = start
            }
        }
        cards.removeAll(); pausedAt = nil; shownDrafts.removeAll()
    }

    mutating func observe(_ event: [String: Any], now: Double) {
        switch event["type"] as? String {
        case "started": reset()
        case "caption_preview":
            guard !finished, let anchor = event["after_sentence_id"] as? String,
                  anchor == latestSourceID,
                  let translation = event["translation"] as? String else { return }
            let text = SubtitlePresentation.singleLine(translation)
            let source = event["preview_source"] as? String
            var draft = Draft(text: text, source: source, anchor: anchor)
            let baseSource = event["preview_base_source"] as? String
            if anchor == latestDraftAnchor {
                guard targetLanguage == "en", let source,
                      let prior = drafts.last(where: { $0.anchor == anchor }) ?? shownDrafts[anchor],
                      let previousSource = prior.source, source != previousSource else { return }
                if let baseSource {
                    let prefix = prior.text + " "
                    guard Self.equalCaptionSource(previousSource, baseSource),
                          text.hasPrefix(prefix) else { return }
                    draft.baseSource = baseSource
                    draft.delta = String(text.dropFirst(prefix.count))
                } else if !Self.sourceExtendsPreview(previousSource, source) {
                    return
                }
            } else if baseSource != nil {
                return
            }
            let reading = draft.delta ?? text
            if !reading.isEmpty, SubtitleReading.work(reading) <= screenWorkLimit + 0.000_001
                || (targetLanguage == "en" && source != nil && !previewPages(reading).isEmpty)
                || (source != nil && shownDrafts[anchor] != nil) {
                if draft.delta == nil { drafts.removeAll { $0.anchor == anchor } }
                guard drafts.count < 8 else { return }
                latestDraftAnchor = anchor
                drafts.append(draft)
            }
        case "sentence_reset":
            drafts.removeAll(); shownDrafts.removeAll(); pendingCaptionTails.removeAll(); latestSourceID = ""; latestDraftAnchor = nil
            if ["final_redecode", "final_commit_reconcile"].contains(event["reason"] as? String ?? "") {
                observeSourceRebuild(event)
            } else { reset() }
        case "final":
            for id in Array(pendingCaptionTails.keys) { finishPendingCaptionTail(id, now: now) }
            drafts.removeAll(); shownDrafts.removeAll(); finished = true; finishSourceRebuild()
        case "caption_tail":
            guard let id = event["sentence_id"] as? String,
                  let waiting = pendingCaptionTails[id],
                  let revision = event["revision"] as? Int, revision == waiting.event["revision"] as? Int,
                  let prefix = event["caption_prefix"] as? String, prefix == waiting.event["caption_prefix"] as? String
            else { return }
            finishPendingCaptionTail(id, now: now, tail: event["translation"] as? String)
        case "sentence_superseded":
            guard let id = event["sentence_id"] as? String, !id.isEmpty,
                  let revision = event["revision"] as? Int, revision >= 0,
                  let replacement = event["replacement_sentence_id"] as? String,
                  !replacement.isEmpty, replacement != id,
                  let replacementRevision = event["replacement_revision"] as? Int,
                  replacementRevision >= 0 else { return }
            if let row = rows.first(where: { $0.id == id }), row.revision != revision { return }
            supersededIDs.insert(id)
            pendingCaptionTails.removeValue(forKey: id)
            for index in drafts.indices where drafts[index].replacementID == id {
                drafts[index].replacementID = replacement
            }
            shownDrafts = shownDrafts.filter { $0.value.replacementID != id }
            pendingReplacements[id] = Replacement(id: replacement, revision: replacementRevision)
            if let index = rows.firstIndex(where: { $0.id == id }) { restoreCompletedFallback(at: index) }
            if let owner = rows.first(where: { $0.id == replacement }),
               owner.revision >= replacementRevision, owner.displayRevision == owner.revision,
               owner.pages != nil, !owner.translation.isEmpty {
                completeReplacement(replacement, revision: owner.revision)
            }
            // Preserve an already visible card for its complete reading turn.
            // Late source/MT is terminal; completed unread fallback is held
            // until a successful owner translation can cover it.
        case "sentence_translation_failed":
            // Operational notices belong in the App/monitor, never the overlay.
            guard let id = event["sentence_id"] as? String,
                  let revision = event["revision"] as? Int,
                  let index = rows.firstIndex(where: { $0.id == id && $0.revision == revision }),
                  rows[index].pages == nil else { return }
            rows[index].failedRevision = revision
            pendingCaptionTails.removeValue(forKey: id)
            drafts.removeAll { $0.replacementID == id }
            shownDrafts = shownDrafts.filter { $0.value.replacementID != id }
            restoreCompletedFallback(at: index)
        case "sentence_committed", "sentence_updated":
            guard let id = event["sentence_id"] as? String, !id.isEmpty,
                  !supersededIDs.contains(id),
                  let revision = event["revision"] as? Int, revision >= 0,
                  let source = event["text"] as? String else { return }
            if event["type"] as? String == "sentence_committed" {
                if var continuation = event["caption_continuation"] as? [String: Any] {
                    continuation["type"] = "caption_preview"
                    observe(continuation, now: now)
                }
                for index in drafts.indices where drafts[index].replacementID == nil {
                    drafts[index].replacementID = id
                }
                if shownDrafts[latestSourceID]?.replacementID == nil {
                    shownDrafts[latestSourceID]?.replacementID = id
                }
                latestSourceID = id
            }
            if suppressRebuiltSource(event, id: id, revision: revision) { return }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                guard revision >= rows[index].revision else { return }
                if revision != rows[index].revision || source != rows[index].source {
                    let previous = rows[index]
                    rows[index] = Row(id: id, revision: revision, source: source,
                                      previousPages: previous.pages ?? previous.previousPages,
                                      previousNextPage: previous.pages == nil ? previous.previousNextPage : previous.nextPage,
                                      previousCompleted: previous.completed ?? previous.previousCompleted)
                }
            } else { rows.append(Row(id: id, revision: revision, source: source)) }
            if let limit = rebuildFallback?.tokens?.count,
               let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index].canonicalRange = Self.canonicalRange(event, limit: limit)
            }
        case "sentence_translation":
            guard let stable = event["is_stable"] as? NSNumber,
                  CFGetTypeID(stable) == CFBooleanGetTypeID(), stable.boolValue,
                  let id = event["sentence_id"] as? String,
                  !supersededIDs.contains(id),
                  let revision = event["revision"] as? Int,
                  rebuildProjection?.ignoredRows[id] != revision,
                  let translation = event["translation"] as? String,
                  !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let index = rows.firstIndex(where: { $0.id == id && $0.revision == revision }) else { return }
            if let projection = rebuildProjection,
               Self.nonnegativeInteger(event["source_token_epoch"] ?? event["new_epoch"]) != projection.epoch { return }
            if let limit = rebuildFallback?.tokens?.count {
                rows[index].canonicalRange = Self.canonicalRange(event, limit: limit)
            }
            let fullText = SubtitlePresentation.singleLine(translation)
            let prefix = event["caption_prefix"] as? String
            let preview = shownDrafts.values.first { $0.replacementID == id }
            let coverage = targetLanguage == "en" ? prefix.flatMap { previewCoverage(id: id, prefix: $0) } : nil
            if let coverage, event["caption_tail_expected"] as? Bool == true,
               !coverage.waiting.isEmpty || preview?.shownPages.last.map({
                   Self.englishDraftContinuation(of: fullText, after: $0.translationPrefix) == nil
               }) == true {
                pendingCaptionTails[id] = PendingCaptionTail(event: event, expiresAt: now + 1.45)
                return
            }
            pendingCaptionTails.removeValue(forKey: id)
            drafts.removeAll { $0.replacementID == id }
            if let preview { shownDrafts.removeValue(forKey: preview.anchor) }
            let completedEnglish = targetLanguage == "en" ? (rows[index].completed ?? rows[index].previousCompleted) : nil
            rows[index].failedRevision = nil
            rows[index].translation = fullText
            rows[index].sourceTokens = Self.tokens(event["source_token_ids"])
            if let epoch = event["source_token_epoch"] as? NSNumber,
               CFGetTypeID(epoch) != CFBooleanGetTypeID(), epoch.doubleValue.isFinite,
               epoch.doubleValue >= 0, epoch.doubleValue == Double(epoch.intValue) {
                rows[index].sourceTokenEpoch = "ledger:\(epoch.intValue)"
            } else { rows[index].sourceTokenEpoch = "visual:\(sourceEpoch)" }
            if let prior = completedEnglish, prior.translation == fullText {
                // Manual font reflow may have changed the physical pages since
                // the original MT arrived. The same whole translation keeps its
                // actual unread cursor, rather than recomputing a different page
                // array and replaying already-read text at page zero.
                rows[index].pages = prior.pages; rows[index].nextPage = prior.nextPage
                rows[index].readyAt = prior.readyAt; rows[index].displayRevision = revision
                for card in cards.indices {
                    for part in cards[card].parts.indices where cards[card].parts[part].id == id {
                        cards[card].parts[part].revision = revision
                    }
                }
                for part in references.indices where references[part].id == id { references[part].revision = revision }
                rows[index].previousPages = nil; rows[index].previousNextPage = 0; rows[index].previousCompleted = nil
                completeReplacement(id, revision: revision)
                return
            }
            var displayText = fullText
            var readPages: [String] = []
            var stagedPages: [String] = []
            if let coverage,
               let suffix = event["caption_tail_translation"] as? String
                   ?? ((event["caption_tail_expected"] as? Bool == false) ? "" : nil) {
                readPages = coverage.read
                stagedPages = coverage.waiting
                displayText = SubtitlePresentation.singleLine(suffix)
                if let last = readPages.last, references.isEmpty && text == last {
                    references = [(id, revision, readPages.count - 1)]
                }
            } else if targetLanguage == "en", let preview {
                for page in preview.shownPages.indices.reversed() {
                    let shown = preview.shownPages[page]
                    guard Self.sourceExtendsPreview(shown.sourcePrefix, rows[index].source),
                          let suffix = Self.englishDraftContinuation(of: fullText, after: shown.translationPrefix)
                    else { continue }
                    displayText = suffix
                    readPages = preview.shownPages.prefix(page + 1).map(\.displayText)
                    // Keep the current turn frozen. Its reference can be
                    // confirmed only when the actual visible page still agrees.
                    if page == preview.shownPages.count - 1 {
                        if let card = cards.firstIndex(where: { $0.parts.isEmpty && $0.text == shown.displayText }) {
                            cards[card].parts = [Part(id: id, revision: revision, page: page, text: shown.displayText)]
                        }
                        if references.isEmpty && text == shown.displayText {
                            references = [(id, revision, page)]
                        }
                    }
                    break
                }
                if readPages.isEmpty, let first = preview.shownPages.first,
                   Self.sourceExtendsPreview(first.sourcePrefix, rows[index].source),
                   let (known, suffix) = Self.sharedEnglishClause(from: first.displayText, in: fullText) {
                    readPages = [known]
                    displayText = suffix
                }
            } else if let prior = completedEnglish, prior.pages.count > 1,
                      prior.sourceTokenEpoch == rows[index].sourceTokenEpoch,
                      let first = prior.sourceTokens?.first, first == rows[index].sourceTokens?.first {
                // Compare the actual pages that reached the screen, before
                // applying the new sentence's wrapping and page boundaries.
                var priorRemaining = prior.translation
                for page in prior.pages.prefix(prior.nextPage) {
                    guard let oldSuffix = Self.englishSuffix(of: priorRemaining, after: page),
                          let newSuffix = Self.englishSuffix(of: displayText, after: page) else { break }
                    readPages.append(page)
                    displayText = newSuffix
                    priorRemaining = oldSuffix
                }
            }
            // Trim only an exact already-displayed prefix of the same source
            // occurrence. Rephrased/corrected translations retain a full turn.
            if readPages.isEmpty, let tokens = rows[index].sourceTokens,
               let prior = displayedCoverage.last(where: { $0.id == id
                   && $0.epoch == rows[index].sourceTokenEpoch
                   && tokens.count > $0.tokens.count && tokens.starts(with: $0.tokens)
                   && fullText.count > $0.text.count && fullText.hasPrefix($0.text) }),
               prior.text.last.map({ ".!?。！？।॥".contains($0) }) == true {
                displayText = String(fullText.dropFirst(prior.text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let budget = min(12, screenWorkLimit)
            let unreadPages = displayText.isEmpty ? [] : (targetLanguage == "en"
                ? englishDisplayPages(displayText, budget: budget)
                : SubtitleReading.pages(displayText, budget: budget).flatMap(splitToFit))
            let pages = readPages + stagedPages + unreadPages
            if rows[index].pages == pages {
                rows[index].displayRevision = revision
                for card in cards.indices {
                    for part in cards[card].parts.indices where cards[card].parts[part].id == id {
                        cards[card].parts[part].revision = revision
                    }
                }
                for part in references.indices where references[part].id == id { references[part].revision = revision }
                rows[index].previousCompleted = nil
                completeReplacement(id, revision: revision)
                return
            }
            let unchanged = rows[index].previousPages == pages
            rows[index].pages = pages; rows[index].nextPage = readPages.count; rows[index].readyAt = now
            rows[index].displayRevision = revision
            // Identical multi-page revisions preserve both visible and already
            // read progress. A source re-decode must not replay the entire row.
            if unchanged || !readPages.isEmpty {
                if unchanged { rows[index].nextPage = max(readPages.count, rows[index].previousNextPage) }
                for card in cards.indices {
                    for part in cards[card].parts.indices where cards[card].parts[part].id == id
                        && (unchanged || cards[card].parts[part].page < readPages.count) {
                        cards[card].parts[part].revision = revision
                    }
                }
                // Keep revision bookkeeping current without changing the
                // visible page identity or restarting its reading time.
                for part in references.indices where references[part].id == id
                    && (unchanged || references[part].page < readPages.count) {
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
            rows[index].previousCompleted = nil
            completeReplacement(id, revision: revision)
        default: break
        }
    }

    @discardableResult mutating func advance(now: Double, visible: Bool = true) -> Bool {
        for id in pendingCaptionTails.compactMap({ $0.value.expiresAt <= now ? $0.key : nil }) {
            finishPendingCaptionTail(id, now: now)
        }
        if !visible { if pausedAt == nil { pausedAt = now }; return false }
        if let pausedAt {
            for index in cards.indices {
                cards[index].deadline += max(0, now - pausedAt)
                cards[index].readingEnd += max(0, now - pausedAt)
            }
            self.pausedAt = nil
        }
        if let last = cards.last {
            deadline = last.deadline
            guard now >= last.deadline else { return false }
            cards.removeAll()
        }
        // Full-session canonical rebuilds finish as one visual transaction.
        // Normal live translation events never pass through this gate.
        if rebuildFallback != nil { return false }
        // Completed history is bounded; unread rows are never evicted to catch up.
        if rows.count > 500 {
            var removable = rows.count - 500
            rows.removeAll { row in
                guard removable > 0, let pages = row.pages, row.nextPage >= pages.count,
                      !row.translation.isEmpty,
                      row.failedRevision == nil,
                      !cards.contains(where: { $0.parts.contains(where: { $0.id == row.id }) }) else { return false }
                removable -= 1; return true
            }
        }
        // Build a complete screen from material available at this boundary.
        // All groups assembled in this call become visible together and share
        // the minimum hold. Nothing is appended on a later timer tick.
        while cards.count < (compact ? 1 : 8) {
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
                let displayRevision = row.displayRevision ?? row.revision
                if cards.contains(where: { $0.parts.contains(where: { $0.id == row.id && ($0.revision != displayRevision || $0.page == row.nextPage) }) }) { break }
                let page = pages[row.nextPage]
                let candidate = SubtitlePresentation.joined([combined, page])
                let englishCondition = targetLanguage == "en" && parts.count == 1 && row.nextPage == 0
                    && combined.lowercased().hasPrefix("if ") && (combined.hasSuffix("…") || combined.hasSuffix("..."))
                if compact && (parts.count >= 2 || (SubtitleReading.work(combined) >= 3 && !englishCondition)) { break }
                if !combined.isEmpty && (SubtitleReading.work(combined) >= 8 || SubtitleReading.work(candidate) > 12) { break }
                let screen = SubtitlePresentation.joined(cards.map { $0.text } + [candidate])
                if SubtitleReading.work(screen) > screenWorkLimit + 0.000_001 { break }
                if !fits(screen) { break }
                combined = candidate
                parts.append(Part(id: row.id, revision: displayRevision, page: row.nextPage, text: page))
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
                if let index = rows.firstIndex(where: { $0.id == part.id && ($0.displayRevision ?? $0.revision) == part.revision }) {
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
            let rate = SubtitleTimingPolicy.characterLanguages[targetLanguage]?.paceFactor ?? readingRate
            let readingEnd = max(now, cards.last?.readingEnd ?? now) + SubtitleReading.work(combined) / rate
            let until = max(now + (SubtitleTimingPolicy.characterLanguages[targetLanguage]?.minimumSeconds ?? 3), readingEnd)
            cards.append(Card(parts: parts, text: combined, readingEnd: readingEnd, deadline: until))
            displayedPages += parts.count
        }
        // A confirmed clause can use an idle screen while an older row awaits
        // translation. Its reading turn never consumes that older row.
        if cards.isEmpty, !finished, var draft = drafts.first {
            let next = rows.first(where: { $0.pages == nil || $0.nextPage < $0.pages!.count })
            if draft.replacementID.flatMap({ pendingCaptionTails[$0] }) == nil,
               next == nil || (next?.pages == nil && (next?.id == draft.replacementID
                   || (targetLanguage == "en" && draft.source != nil))) {
                if draft.displayPages.isEmpty {
                    var nextText: String? = draft.text
                    if let prior = shownDrafts[draft.anchor] {
                        if let base = draft.baseSource {
                            nextText = Self.equalCaptionSource(prior.source ?? "", base) ? draft.delta : nil
                        } else {
                            nextText = Self.englishDraftContinuation(of: draft.text, after: prior.text)
                        }
                        draft.shownPages = prior.shownPages
                    } else if draft.baseSource != nil {
                        nextText = nil
                    }
                    draft.displayPages = nextText.map(previewPages) ?? []
                }
                if draft.nextDisplayPage < draft.displayPages.count {
                    let nextText = draft.displayPages[draft.nextDisplayPage]
                    draft.nextDisplayPage += 1
                    if draft.nextDisplayPage == draft.displayPages.count {
                        drafts.removeFirst()
                        if targetLanguage == "en", let source = draft.source {
                            draft.shownPages += draft.displayPages.indices.map { index in
                                let last = index == draft.displayPages.count - 1
                                return DraftPage(displayText: draft.displayPages[index], sourcePrefix: last ? source : "",
                                                 translationPrefix: last ? draft.text : "")
                            }
                            shownDrafts[draft.anchor] = draft
                        }
                    } else {
                        drafts[0] = draft
                    }
                    let until = now + compactSeconds(nextText)
                    cards.append(Card(parts: [], text: nextText, readingEnd: until, deadline: until))
                } else {
                    drafts.removeFirst()
                }
            }
        }
        if let last = cards.indices.last, !cards[last].parts.isEmpty {
            let screen = SubtitlePresentation.joined(cards.map { $0.text })
            if compact {
                cards[last].deadline = now + compactSeconds(screen)
            } else {
                if let timing { cards[last].deadline = now + timing.seconds(screen) }
                else if let policy = SubtitleTimingPolicy.characterLanguages[targetLanguage] {
                    cards[last].deadline = now + max(policy.minimumSeconds, SubtitleReading.work(screen) / policy.paceFactor)
                }
                cards[last].deadline += SubtitleReading.additionalSeconds(
                    screen, targetLanguage: targetLanguage)
            }
        }
        deadline = cards.last?.deadline ?? now
        guard !cards.isEmpty else { return false } // Keep final text visible.
        let updated = SubtitlePresentation.joined(cards.map { $0.text })
        let refs = cards.flatMap { $0.parts.map { ($0.id, $0.revision, $0.page) } }
        let presented = Set(refs.map { $0.0 })
        drafts.removeAll { $0.replacementID.map(presented.contains) == true }
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
