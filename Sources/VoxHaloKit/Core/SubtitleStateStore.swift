import Foundation

public struct SubtitleStateStore: Sendable {
    private var direction: TranslationDirection
    public private(set) var rows: [SubtitleRow] = []
    public private(set) var current: SubtitleDisplayModel

    private var displayedTranslations: [String: String] = [:]
    private var stableSourceSentenceIDs: Set<String> = []
    private var frozenTranslationPrefixes: [String: String] = [:]
    private var translationRewriteCounts: [String: Int] = [:]
    private var aggregatePrimaryText = ""
    private var displayedAggregatePrimaryText = ""
    private var aggregateDisplayBaseText = ""
    private var aggregatePrimaryAllowsLooseTail = false
    private var committedReferenceAggregateRawText = ""
    private var committedReferenceAggregateText = ""
    private var referenceSentenceID: String?
    private var referenceText = ""
    private var cachedPrimarySegments: [String] = []
    private var cachedReferenceSegments: [String] = []
    private var primarySegmentsDirty = false
    private var referenceSegmentsDirty = false
    private var isProcessing = false
    private var reconciliationDisplaySnapshot: SubtitleDisplayModel?

    public init(direction: TranslationDirection) {
        self.direction = direction
        self.current = .empty(for: direction)
    }

    public mutating func reset(direction: TranslationDirection) {
        self.direction = direction
        reconciliationDisplaySnapshot = nil
        clearSubtitleState()
        current = .empty(for: direction)
    }

    @discardableResult
    public mutating func apply(_ event: VoxBridgeEvent) -> SubtitleDisplayModel {
        recordSourceStability(event)
        let releasesReconciliationSnapshot = event.type == .final
        switch event.type {
        case .sentenceCommitted:
            upsertSource(event)
        case .sentenceUpdated:
            upsertSource(event)
        case .sentenceTranslation:
            applyTranslation(event)
        case .partial:
            applyPartialCommittedAggregate(event)
            applyLiveReference(event)
        case .sentenceReset:
            beginSentenceReset(event)
        case .processing:
            isProcessing = true
        case .final:
            applyFinal(event)
        case .unknown, .ready, .started, .translationDirection, .error, .pong:
            break
        }

        let rebuilt = buildCurrent()
        if releasesReconciliationSnapshot {
            if rebuilt.primaryText.isEmpty,
               let snapshot = reconciliationDisplaySnapshot,
               !snapshot.primaryText.isEmpty {
                current = snapshot
            } else {
                current = rebuilt
            }
            reconciliationDisplaySnapshot = nil
        } else if let snapshot = reconciliationDisplaySnapshot {
            current = snapshot
        } else {
            current = rebuilt
        }
        return current
    }

    private mutating func beginSentenceReset(_ event: VoxBridgeEvent) {
        let reason = event.reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let preservesVisibleDisplay = reason == "final_redecode"
            || reason == "final_commit_reconcile"
        let snapshot = preservesVisibleDisplay ? current : nil
        clearSubtitleState()
        reconciliationDisplaySnapshot = snapshot
    }

    private mutating func upsertSource(_ event: VoxBridgeEvent) {
        guard let sentenceID = nonBlank(event.sentenceID),
              let source = nonBlank(event.text) else {
            return
        }

        let existingIndex = rows.firstIndex { $0.sentenceID == sentenceID }
        let existing = existingIndex.map { rows[$0] }
        let row = SubtitleRow(
            sentenceID: sentenceID,
            sourceText: source,
            translation: existing?.translation ?? "",
            sequence: max(existing?.sequence ?? 0, event.sequence ?? 0),
            timestampMilliseconds: event.timestampMilliseconds ?? existing?.timestampMilliseconds
        )

        if let existingIndex {
            rows[existingIndex] = row
        } else {
            rows.append(row)
        }

        if existingIndex == nil || sentenceID == referenceSentenceID || existingIndex == rows.count - 1 {
            updateReferenceText(sentenceID: sentenceID, text: row.sourceText)
        }

        referenceSegmentsDirty = true
    }

    private mutating func recordSourceStability(_ event: VoxBridgeEvent) {
        let phase = event.stability?.phase?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard event.isStable == true
            || event.stability?.isStable == true
            || phase == "solidified" else {
            return
        }
        guard let sentenceID = nonBlank(
            event.sentenceID ?? event.stability?.sentenceID
        ) else {
            return
        }
        stableSourceSentenceIDs.insert(sentenceID)
        if let displayed = displayedTranslations[sentenceID] {
            frozenTranslationPrefixes[sentenceID] = displayed
        }
    }

    private mutating func updateReferenceText(sentenceID: String?, text: String) {
        guard let nextText = nonBlank(text) else {
            return
        }
        if let sentenceID = nonBlank(sentenceID) {
            referenceSentenceID = sentenceID
        }
        if referenceText != nextText {
            referenceText = nextText
            referenceSegmentsDirty = true
        }
    }

    private mutating func applyTranslation(_ event: VoxBridgeEvent) {
        guard let sentenceID = nonBlank(event.sentenceID),
              let translation = nonBlank(event.translation) else {
            return
        }

        var index: Int
        if let existingIndex = rows.firstIndex(where: { $0.sentenceID == sentenceID }) {
            index = existingIndex
        } else {
            rows.append(SubtitleRow(
                sentenceID: sentenceID,
                sourceText: "",
                translation: translation,
                sequence: event.sequence ?? 0,
                timestampMilliseconds: event.timestampMilliseconds
            ))
            index = rows.count - 1
            referenceSegmentsDirty = true
        }

        let oldRow = rows[index]
        rows[index] = SubtitleRow(
            sentenceID: sentenceID,
            sourceText: oldRow.sourceText,
            translation: translation,
            sequence: max(oldRow.sequence, event.sequence ?? oldRow.sequence),
            timestampMilliseconds: event.timestampMilliseconds ?? oldRow.timestampMilliseconds
        )

        updateDisplayedTranslation(
            translation,
            sentenceID: sentenceID
        )
    }

    private mutating func updateDisplayedTranslation(
        _ value: String,
        sentenceID: String
    ) {
        let translation = SubtitleText.normalized(value)
        guard !translation.isEmpty else { return }

        guard let displayed = displayedTranslations[sentenceID] else {
            acceptDisplayedTranslation(translation, sentenceID: sentenceID)
            return
        }
        guard translation != displayed else { return }

        // Once a newer source sentence exists, every earlier rendered sentence
        // becomes immutable. Canonical rows still receive backend corrections,
        // but the reader's visible history and scroll anchor do not move.
        guard rows.last?.sentenceID == sentenceID else { return }

        // Growth that preserves every already-rendered character is always safe.
        if translation.hasPrefix(displayed) {
            acceptDisplayedTranslation(translation, sentenceID: sentenceID)
            return
        }

        // Never move the live translation backwards. A shorter revision causes
        // the most disruptive reflow and usually represents an intermediate ASR
        // rollback rather than useful new information.
        guard translation.count >= displayed.count else { return }

        if let frozenPrefix = frozenTranslationPrefixes[sentenceID],
           !frozenPrefix.isEmpty {
            guard translation.hasPrefix(frozenPrefix) else { return }
            guard !stableSourceSentenceIDs.contains(sentenceID) else { return }
            let rewriteCount = translationRewriteCounts[sentenceID, default: 0]
            guard rewriteCount == 0 else { return }
            translationRewriteCounts[sentenceID] = rewriteCount + 1
            acceptDisplayedTranslation(translation, sentenceID: sentenceID)
            return
        }

        guard !stableSourceSentenceIDs.contains(sentenceID) else { return }

        // For an unpunctuated live tail, permit one structural correction. This
        // avoids locking the very first rough draft while bounding visual churn.
        let rewriteCount = translationRewriteCounts[sentenceID, default: 0]
        guard rewriteCount == 0 else { return }
        translationRewriteCounts[sentenceID] = rewriteCount + 1
        acceptDisplayedTranslation(translation, sentenceID: sentenceID)
    }

    private mutating func acceptDisplayedTranslation(
        _ translation: String,
        sentenceID: String
    ) {
        displayedTranslations[sentenceID] = translation
        if stableSourceSentenceIDs.contains(sentenceID) {
            frozenTranslationPrefixes[sentenceID] = translation
            translationRewriteCounts[sentenceID] = 0
        } else {
            let completedPrefix = completedTranslationPrefix(translation)
            let oldPrefix = frozenTranslationPrefixes[sentenceID] ?? ""
            if completedPrefix.count > oldPrefix.count,
               completedPrefix.hasPrefix(oldPrefix) {
                frozenTranslationPrefixes[sentenceID] = completedPrefix
                translationRewriteCounts[sentenceID] = 0
            }
        }
        primarySegmentsDirty = true
    }

    private func completedTranslationPrefix(_ translation: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ";", "；"]
        let closingCharacters: Set<Character> = [
            "\"", "'", "”", "’", ")", "]", "}", "）", "】", "》", "」", "』"
        ]
        var completedEnd: String.Index?

        var index = translation.startIndex
        while index < translation.endIndex {
            let character = translation[index]
            let next = translation.index(after: index)
            if terminators.contains(character) {
                var end = next
                while end < translation.endIndex,
                      closingCharacters.contains(translation[end]) {
                    end = translation.index(after: end)
                }
                completedEnd = end
            }
            index = next
        }

        guard let completedEnd else { return "" }
        return SubtitleText.normalized(String(translation[..<completedEnd]))
    }

    private mutating func applyFinal(_ event: VoxBridgeEvent) {
        isProcessing = false
        if referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let fallback = firstNonBlank([
               event.tentativeText,
               event.text,
               event.committedText
           ]) {
            updateReferenceText(sentenceID: event.sentenceID, text: fallback)
        }
        applyCommittedReferenceAggregate(event.committedText)
        applyAggregateTranslation(event.translation, allowLooseTail: true)
    }

    private mutating func applyPartialCommittedAggregate(_ event: VoxBridgeEvent) {
        guard nonBlank(event.committedText) != nil else {
            return
        }
        applyCommittedReferenceAggregate(event.committedText)
        applyPartialAggregateTranslation(event.translation)
    }

    private mutating func applyCommittedReferenceAggregate(_ value: String?) {
        guard let raw = nonBlank(value), raw != committedReferenceAggregateRawText else {
            return
        }
        let aggregate = SubtitleText.normalized(raw)
        guard !aggregate.isEmpty else {
            return
        }
        committedReferenceAggregateRawText = raw
        if aggregate != committedReferenceAggregateText {
            committedReferenceAggregateText = aggregate
            referenceSegmentsDirty = true
        }
    }

    private mutating func applyPartialAggregateTranslation(_ value: String?) {
        let aggregate = SubtitleText.normalized(value ?? "")
        let structuredText = SubtitleText.joined(buildDisplayedPrimarySegments())
        guard !aggregate.isEmpty,
              aggregate != aggregatePrimaryText,
              canUsePartialAggregateTranslation(aggregate) else {
            return
        }
        aggregatePrimaryText = aggregate
        aggregatePrimaryAllowsLooseTail = false

        if displayedAggregatePrimaryText.isEmpty
            || aggregateDisplayBaseText != structuredText {
            aggregateDisplayBaseText = structuredText
            displayedAggregatePrimaryText = aggregate
            primarySegmentsDirty = true
            return
        }

        // Partial aggregate translations are fallback text. Once shown, they may
        // grow but never structurally rewrite the reader's visible paragraph.
        // A later canonical sentence_translation or final event can replace the
        // fallback exactly once at its authoritative boundary.
        if aggregate.hasPrefix(displayedAggregatePrimaryText) {
            displayedAggregatePrimaryText = aggregate
            primarySegmentsDirty = true
        }
    }

    private func canUsePartialAggregateTranslation(_ aggregate: String) -> Bool {
        let displayedText = SubtitleText.joined(buildDisplayedPrimarySegments())
        return displayedText.isEmpty || aggregate.hasPrefix(displayedText)
    }

    private mutating func applyAggregateTranslation(_ value: String?, allowLooseTail: Bool) {
        let aggregate = SubtitleText.normalized(value ?? "")
        guard !aggregate.isEmpty else {
            return
        }
        if aggregate != aggregatePrimaryText || aggregatePrimaryAllowsLooseTail != allowLooseTail {
            aggregatePrimaryText = aggregate
            displayedAggregatePrimaryText = aggregate
            aggregateDisplayBaseText = SubtitleText.joined(buildDisplayedPrimarySegments())
            aggregatePrimaryAllowsLooseTail = allowLooseTail
            primarySegmentsDirty = true
        }
    }

    private mutating func applyLiveReference(_ event: VoxBridgeEvent) {
        let live = buildLiveReferenceText(event)
        if !live.isEmpty {
            updateReferenceText(sentenceID: event.sentenceID, text: live)
        }
    }

    private func buildLiveReferenceText(_ event: VoxBridgeEvent) -> String {
        let candidate = event.textReset == true
            ? firstNonBlank([
                event.tentativeText,
                event.stateText,
                event.text,
                event.deltaText,
                event.committedText
            ])
            : firstNonBlank([
                event.tentativeText,
                event.text,
                event.stateText,
                event.committedText
            ])

        guard let candidate else {
            return ""
        }
        let liveReference = SubtitleText.normalized(candidate)
        if event.textReset == true {
            return liveReference
        }

        if let committed = nonBlank(event.committedText),
           let tail = removingPrefix(candidate, prefix: committed),
           !SubtitleText.normalized(tail).isEmpty {
            return SubtitleText.normalized(tail)
        }

        let referencePrefix = SubtitleText.normalized(referenceText)
        if !referencePrefix.isEmpty,
           let remainder = removingPrefix(liveReference, prefix: referencePrefix),
           !SubtitleText.normalized(remainder).isEmpty {
            return SubtitleText.normalized(remainder)
        }

        if nonBlank(event.tentativeText) != nil {
            return liveReference
        }

        let committedPrefix = SubtitleText.normalized(event.committedText ?? "")
        if !committedPrefix.isEmpty,
           let remainder = removingPrefix(liveReference, prefix: committedPrefix),
           !SubtitleText.normalized(remainder).isEmpty {
            return SubtitleText.normalized(remainder)
        }

        return liveReference
    }

    private mutating func clearSubtitleState() {
        rows.removeAll(keepingCapacity: true)
        displayedTranslations.removeAll(keepingCapacity: true)
        stableSourceSentenceIDs.removeAll(keepingCapacity: true)
        frozenTranslationPrefixes.removeAll(keepingCapacity: true)
        translationRewriteCounts.removeAll(keepingCapacity: true)
        aggregatePrimaryText = ""
        displayedAggregatePrimaryText = ""
        aggregateDisplayBaseText = ""
        aggregatePrimaryAllowsLooseTail = false
        committedReferenceAggregateRawText = ""
        committedReferenceAggregateText = ""
        referenceSentenceID = nil
        referenceText = ""
        cachedPrimarySegments = []
        cachedReferenceSegments = []
        primarySegmentsDirty = false
        referenceSegmentsDirty = false
        isProcessing = false
    }

    private mutating func buildCurrent() -> SubtitleDisplayModel {
        ensurePrimaryDisplayCache()
        ensureReferenceDisplayCache()
        return SubtitleDisplayModel(
            cachedPrimarySegments: cachedPrimarySegments,
            cachedReferenceSegments: cachedReferenceSegments,
            referenceText: referenceText,
            targetLanguage: direction.targetLanguageLabel,
            sourceLanguage: direction.sourceLanguageLabel,
            isProcessing: isProcessing
        )
    }

    private mutating func ensurePrimaryDisplayCache() {
        guard primarySegmentsDirty else {
            return
        }
        cachedPrimarySegments = buildPrimarySegments()
        primarySegmentsDirty = false
    }

    private mutating func ensureReferenceDisplayCache() {
        guard referenceSegmentsDirty else {
            return
        }
        cachedReferenceSegments = buildReferenceSegments()
        referenceSegmentsDirty = false
    }

    private func buildPrimarySegments() -> [String] {
        var segments = buildDisplayedPrimarySegments()
        let structuredText = SubtitleText.joined(segments)
        let aggregate = SubtitleText.normalized(displayedAggregatePrimaryText)

        if segments.isEmpty {
            appendIfNotBlank(aggregate, to: &segments)
            return Array(segments.suffix(SubtitleText.maximumPrimarySegments))
        }

        if aggregate.count > structuredText.count, aggregate.hasPrefix(structuredText) {
            appendIfNotBlank(String(aggregate.dropFirst(structuredText.count)), to: &segments)
        } else if aggregatePrimaryAllowsLooseTail {
            appendIfNotBlank(
                extractTailAfterLastDisplayedSegment(segments: segments, aggregate: aggregate),
                to: &segments
            )
        }

        return Array(segments.suffix(SubtitleText.maximumPrimarySegments))
    }

    private func buildDisplayedPrimarySegments() -> [String] {
        rows.compactMap { row in
            guard let value = displayedTranslations[row.sentenceID] else {
                return nil
            }
            let normalized = SubtitleText.normalized(value)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func buildReferenceSegments() -> [String] {
        var segments = rows.compactMap { row -> String? in
            let normalized = SubtitleText.normalized(row.sourceText)
            return normalized.isEmpty ? nil : normalized
        }

        addCommittedReferenceAggregateTail(
            segments: &segments,
            aggregate: committedReferenceAggregateText
        )

        let liveReference = SubtitleText.normalized(referenceText)
        if !liveReference.isEmpty,
           segments.last.map({ !$0.caseInsensitiveEquals(liveReference) }) ?? true {
            segments.append(liveReference)
        }

        return Array(segments.suffix(SubtitleText.maximumReferenceSegments))
    }

    private func addCommittedReferenceAggregateTail(
        segments: inout [String],
        aggregate: String
    ) {
        let aggregate = SubtitleText.normalized(aggregate)
        guard !aggregate.isEmpty else {
            return
        }
        if segments.isEmpty {
            appendIfNotBlank(aggregate, to: &segments)
            return
        }

        let structured = SubtitleText.joined(segments)
        if let tail = removingPrefix(aggregate, prefix: structured) {
            appendIfNotBlank(tail, to: &segments)
        } else {
            appendIfNotBlank(
                extractTailAfterLastDisplayedSegment(segments: segments, aggregate: aggregate),
                to: &segments
            )
        }
    }

    private func extractTailAfterLastDisplayedSegment(
        segments: [String],
        aggregate: String
    ) -> String {
        guard let last = segments.last, !last.isEmpty,
              let range = aggregate.range(
                of: SubtitleText.normalized(last),
                options: [.caseInsensitive, .backwards]
              ) else {
            return ""
        }
        return String(aggregate[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstNonBlank(_ values: [String?]) -> String? {
        values.compactMap(nonBlank).first
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func removingPrefix(_ text: String, prefix: String) -> String? {
        guard let range = text.range(
            of: prefix,
            options: [.anchored, .caseInsensitive]
        ) else {
            return nil
        }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendIfNotBlank(_ value: String, to values: inout [String]) {
        let normalized = SubtitleText.normalized(value)
        if !normalized.isEmpty {
            values.append(normalized)
        }
    }
}

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive]) == .orderedSame
    }
}
