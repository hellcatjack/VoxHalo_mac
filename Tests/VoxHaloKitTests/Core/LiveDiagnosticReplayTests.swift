import AppKit
import XCTest
@testable import VoxHaloKit

@MainActor
final class LiveDiagnosticReplayTests: XCTestCase {
    func testOptInLiveDiagnosticReplayPreservesHistoryAndReadingPosition() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VOXHALO_LIVE_DIAGNOSTIC_LOG"],
              !path.isEmpty else {
            throw XCTSkip("Set VOXHALO_LIVE_DIAGNOSTIC_LOG to replay an opted-in live run.")
        }
        let firstLine = max(
            1,
            Int(environment["VOXHALO_LIVE_DIAGNOSTIC_FIRST_LINE"] ?? "1") ?? 1
        )
        let lastLine = environment["VOXHALO_LIVE_DIAGNOSTIC_LAST_LINE"]
            .flatMap(Int.init)
            .map { max(firstLine, $0) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoder = JSONDecoder()
        let records = try text.split(separator: "\n").enumerated().compactMap {
            index, line -> LiveDiagnosticRecord? in
            let lineNumber = index + 1
            guard lineNumber >= firstLine,
                  lastLine.map({ lineNumber <= $0 }) ?? true else {
                return nil
            }
            return try decoder.decode(
                LiveDiagnosticRecord.self,
                from: Data(line.utf8)
            )
        }

        var reconstructor = LiveEventReconstructor()
        let events = records.compactMap { reconstructor.event(from: $0) }
        XCTAssertGreaterThan(events.count, 100)

        var store = SubtitleStateStore(direction: .chineseToEnglish)
        let view = makeReplayView()
        var readerPinned = false
        var verifiedFrozenPrefixes = 0

        for event in events {
            let oldSegments = store.current.primarySegments
            let model = store.apply(event)

            if oldSegments.count > 1 {
                let frozenPrefix = Array(oldSegments.dropLast())
                XCTAssertEqual(
                    Array(model.primarySegments.prefix(frozenPrefix.count)),
                    frozenPrefix,
                    "a live backend event rewrote already rendered history"
                )
                verifiedFrozenPrefixes += 1
            }

            view.apply(model: model)
            view.layoutSubtreeIfNeeded()
            view.flushPendingScrolls()

            if readerPinned {
                XCTAssertEqual(
                    view.targetRegion.contentView.bounds.origin.y,
                    0,
                    accuracy: 0.01,
                    "live updates displaced a reader who had scrolled up"
                )
            } else {
                let maximumY = max(
                    0,
                    view.targetTextView.frame.height
                        - view.targetRegion.contentView.bounds.height
                )
                if maximumY > view.targetTextView.layoutLineHeight * 2 {
                    view.targetRegion.contentView.scroll(to: .zero)
                    view.targetRegion.reflectScrolledClipView(
                        view.targetRegion.contentView
                    )
                    readerPinned = true
                }
            }
        }

        XCTAssertTrue(readerPinned)
        XCTAssertGreaterThan(verifiedFrozenPrefixes, 50)
        XCTAssertGreaterThan(store.current.primarySegments.count, 10)
        XCTAssertGreaterThan(store.current.primaryText.utf16.count, 480)
        XCTAssertEqual(view.targetTextView.text, store.current.primaryText)

        if let finalTranslation = records.last(where: {
            $0.event == "backend" && $0.type == "final"
        })?.translation {
            let displayedWords = normalizedWords(store.current.primaryText)
            let finalWords = normalizedWords(finalTranslation)
            let commonWords = longestCommonSubsequenceLength(
                displayedWords,
                finalWords
            )
            let displayedCoverage = coverage(
                commonCount: commonWords,
                totalCount: displayedWords.count
            )
            let finalCoverage = coverage(
                commonCount: commonWords,
                totalCount: finalWords.count
            )

            XCTAssertGreaterThanOrEqual(
                displayedCoverage,
                0.95,
                "displayed history diverged too far from the authoritative final"
            )
            XCTAssertGreaterThanOrEqual(
                finalCoverage,
                0.95,
                "authoritative final content is missing from the displayed history"
            )

            print(
                "LIVE_REPLAY_METRICS "
                    + "rows=\(store.rows.count) "
                    + "primary_segments=\(store.current.primarySegments.count) "
                    + "reference_segments=\(store.current.referenceSegments.count) "
                    + "displayed_words=\(displayedWords.count) "
                    + "final_words=\(finalWords.count) "
                    + "common_words=\(commonWords) "
                    + "displayed_coverage=\(formatCoverage(displayedCoverage)) "
                    + "final_coverage=\(formatCoverage(finalCoverage))"
            )
        }

        if let outputPath = environment["VOXHALO_LIVE_REPLAY_SNAPSHOT"],
           !outputPath.isEmpty {
            let bitmap = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: view.bounds)
            )
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(
                using: .png,
                properties: [:]
            ))
            try png.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    private func makeReplayView() -> SubtitleOverlayView {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 500)
        )
        view.apply(
            layout: SubtitleLayoutSettings(
                targetAreaHeight: 150,
                targetFontSize: 32,
                targetTopOffset: 0,
                targetColor: "#FFFFFF",
                referenceAreaHeight: 80,
                referenceFontSize: 22,
                referenceBottomOffset: 0,
                referenceColor: "#F4F4F4"
            ),
            display: DisplayDescriptor(
                id: "LIVE-REPLAY-DISPLAY",
                name: "Live Replay Display",
                frame: CGRect(x: 0, y: 0, width: 720, height: 500),
                scale: 2,
                isMain: true
            )
        )
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()
        return view
    }

    private func normalizedWords(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private func longestCommonSubsequenceLength(
        _ lhs: [String],
        _ rhs: [String]
    ) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(repeating: 0, count: rhs.count + 1)
        var current = previous

        for left in lhs {
            current[0] = 0
            for index in rhs.indices {
                if left == rhs[index] {
                    current[index + 1] = previous[index] + 1
                } else {
                    current[index + 1] = max(
                        current[index],
                        previous[index + 1]
                    )
                }
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    private func coverage(commonCount: Int, totalCount: Int) -> Double {
        guard totalCount > 0 else { return 1 }
        return Double(commonCount) / Double(totalCount)
    }

    private func formatCoverage(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

private struct LiveDiagnosticRecord: Decodable {
    let event: String
    let type: String?
    let sequence: Int?
    let transcript: String?
    let translation: String?
    let stability: LiveDiagnosticStability?
}

private struct LiveDiagnosticStability: Decodable {
    let isStable: Bool?
    let phase: String?
    let reason: String?
    let segmentID: Int?
    let sequence: Int?
    let committedCount: Int?
    let tentativeCharacters: Int?
    let unstableCharacters: Int?

    enum CodingKeys: String, CodingKey {
        case isStable = "is_stable"
        case phase
        case reason
        case segmentID = "segment_id"
        case sequence
        case committedCount = "committed_count"
        case tentativeCharacters = "tentative_characters"
        case unstableCharacters = "unstable_characters"
    }
}

private struct LiveEventReconstructor {
    private var committedCount = 0
    private var activeSentenceID: String?
    private var pendingTranslationIDs: [Int: [String]] = [:]
    private var updatedSentenceIDs: [Int: String] = [:]

    mutating func event(from record: LiveDiagnosticRecord) -> VoxBridgeEvent? {
        guard record.event == "backend", let rawType = record.type else {
            return nil
        }
        let type = VoxBridgeEventType(rawType: rawType)
        let sentenceID = sentenceID(for: type, sequence: record.sequence)
        let transcript = loggableBody(record.transcript)
        let translation = loggableBody(record.translation)
        let stability = record.stability.map {
            VoxBridgeStability(
                isStable: $0.isStable,
                phase: $0.phase,
                reason: $0.reason,
                sentenceID: sentenceID,
                segmentID: $0.segmentID,
                sequence: $0.sequence,
                committedCount: $0.committedCount,
                tentativeCharacters: $0.tentativeCharacters,
                unstableCharacters: $0.unstableCharacters
            )
        }

        let event = VoxBridgeEvent(
            type: type,
            rawType: rawType,
            sentenceID: sentenceID,
            text: transcript,
            stateText: type == .partial ? transcript : nil,
            tentativeText: type == .partial ? transcript : nil,
            committedText: type == .partial || type == .final ? transcript : nil,
            translation: translation,
            reason: stability?.reason,
            sequence: record.sequence,
            isStable: stability?.isStable,
            stability: stability
        )

        if type == .sentenceReset {
            activeSentenceID = nil
            pendingTranslationIDs.removeAll(keepingCapacity: true)
            updatedSentenceIDs.removeAll(keepingCapacity: true)
        }
        return event
    }

    private mutating func sentenceID(
        for type: VoxBridgeEventType,
        sequence: Int?
    ) -> String? {
        switch type {
        case .sentenceCommitted:
            committedCount += 1
            let id = "live-sentence-\(committedCount)"
            activeSentenceID = id
            if let sequence {
                pendingTranslationIDs[sequence, default: []].append(id)
            }
            return id

        case .sentenceUpdated:
            guard let id = activeSentenceID else { return nil }
            if let sequence { updatedSentenceIDs[sequence] = id }
            return id

        case .sentenceTranslation:
            if let sequence, let id = updatedSentenceIDs.removeValue(forKey: sequence) {
                return id
            }
            if let sequence, var pending = pendingTranslationIDs[sequence],
               !pending.isEmpty {
                let id = pending.removeFirst()
                pendingTranslationIDs[sequence] = pending.isEmpty ? nil : pending
                return id
            }
            return activeSentenceID

        case .partial, .final, .processing, .sentenceReset:
            return activeSentenceID

        case .unknown, .ready, .started, .translationDirection, .error, .pong:
            return nil
        }
    }

    private func loggableBody(_ value: String?) -> String? {
        guard let value, value != "[REDACTED]", !value.isEmpty else {
            return nil
        }
        return value
    }
}
