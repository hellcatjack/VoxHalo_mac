import Foundation

public struct SubtitleStateStore: Sendable {
    private var direction: TranslationDirection
    public private(set) var rows: [SubtitleRow] = []
    public private(set) var current: SubtitleDisplayModel

    private var displayedTranslations: [String: String] = [:]
    private var translationRefreshSentenceIDs: Set<String> = []
    private var aggregatePrimaryText = ""
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

    public init(direction: TranslationDirection) {
        self.direction = direction
        self.current = .empty(for: direction)
    }

    public mutating func reset(direction: TranslationDirection) {
        self.direction = direction
        clearSubtitleState()
        current = .empty(for: direction)
    }

    @discardableResult
    public mutating func apply(_ event: VoxBridgeEvent) -> SubtitleDisplayModel {
        switch event.type {
        case .sentenceCommitted:
            upsertSource(event, marksTranslationRefresh: false)
        case .sentenceUpdated:
            upsertSource(event, marksTranslationRefresh: true)
        case .sentenceTranslation:
            applyTranslation(event)
        case .partial:
            applyPartialCommittedAggregate(event)
            applyLiveReference(event)
        case .sentenceReset:
            clearSubtitleState()
        case .processing:
            isProcessing = true
        case .final:
            applyFinal(event)
        case .unknown, .ready, .started, .translationDirection, .error, .pong:
            break
        }

        current = buildCurrent()
        return current
    }

    private mutating func upsertSource(
        _ event: VoxBridgeEvent,
        marksTranslationRefresh: Bool
    ) {
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

        if marksTranslationRefresh {
            translationRefreshSentenceIDs.insert(sentenceID)
        }
        referenceSegmentsDirty = true
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

        let lastDisplayedID = lastDisplayedSentenceID()
        let pendingRefresh = translationRefreshSentenceIDs.remove(sentenceID) != nil
        if displayedTranslations[sentenceID] == nil ||
            sentenceID == lastDisplayedID ||
            pendingRefresh {
            displayedTranslations[sentenceID] = translation
            primarySegmentsDirty = true
        }
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
        guard !aggregate.isEmpty,
              aggregate != aggregatePrimaryText,
              canUsePartialAggregateTranslation(aggregate) else {
            return
        }
        applyAggregateTranslation(aggregate, allowLooseTail: false)
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
        translationRefreshSentenceIDs.removeAll(keepingCapacity: true)
        aggregatePrimaryText = ""
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
        let aggregate = SubtitleText.normalized(aggregatePrimaryText)

        if segments.isEmpty {
            appendIfNotBlank(aggregate, to: &segments)
            return Array(segments.suffix(SubtitleText.maximumSegments))
        }

        if aggregate.count > structuredText.count, aggregate.hasPrefix(structuredText) {
            appendIfNotBlank(String(aggregate.dropFirst(structuredText.count)), to: &segments)
        } else if aggregatePrimaryAllowsLooseTail {
            appendIfNotBlank(
                extractTailAfterLastDisplayedSegment(segments: segments, aggregate: aggregate),
                to: &segments
            )
        }

        return Array(segments.suffix(SubtitleText.maximumSegments))
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

        return Array(segments.suffix(SubtitleText.maximumSegments))
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

    private func lastDisplayedSentenceID() -> String? {
        rows.reversed().first { displayedTranslations[$0.sentenceID] != nil }?.sentenceID
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
