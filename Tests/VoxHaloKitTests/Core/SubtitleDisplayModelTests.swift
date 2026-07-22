import XCTest
@testable import VoxHaloKit

final class SubtitleDisplayModelTests: XCTestCase {
    func testStructuredTextNormalizesWhitespaceAndSeparatesStableFromActive() {
        let model = SubtitleDisplayModel(
            stablePrimaryLines: ["  hello\n world ", "\tsecond  line"],
            activePrimaryText: " active\u{00a0}text ",
            referenceText: " source\n text ",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: true
        )

        XCTAssertEqual(model.stablePrimaryLines, ["hello world", "second line"])
        XCTAssertEqual(model.activePrimaryText, "active text")
        XCTAssertEqual(model.stablePrimaryText, "hello world second line")
        XCTAssertEqual(model.primaryText, "hello world second line active text")
        XCTAssertEqual(model.primarySegments, ["hello world", "second line", "active text"])
        XCTAssertEqual(model.referenceText, "source text")
        XCTAssertEqual(model.referenceSegments, ["source text"])
        XCTAssertTrue(model.isProcessing)
    }

    func testPrimaryTextKeepsWholeBoundedSegmentsWithoutCharacterSlidingWindow() {
        let old = String(repeating: "旧", count: 300)
        let active = String(repeating: "👨‍👩‍👧‍👦新", count: 80)
        let model = SubtitleDisplayModel(
            stablePrimaryLines: [old],
            activePrimaryText: active,
            referenceText: "",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )

        XCTAssertEqual(model.primaryText, old + " " + active)
        XCTAssertFalse(model.primaryText.hasPrefix("..."))
        XCTAssertFalse(model.primaryText.contains("�"))
        XCTAssertTrue(model.primaryText.hasSuffix("新"))
    }

    func testPrimaryHistoryKeepsTwoMinuteBufferWhileReferenceKeepsNewest24() {
        let values = (1...30).map { "segment \($0)" }
        let model = SubtitleDisplayModel(
            stablePrimaryLines: Array(values.dropLast()),
            activePrimaryText: values.last!,
            referenceText: "fallback",
            referenceSegments: values,
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )

        XCTAssertEqual(model.primarySegments, values)
        XCTAssertEqual(model.referenceSegments, Array(values.suffix(24)))
    }

    func testEmptyModelUsesDirectionLabels() {
        XCTAssertEqual(
            SubtitleDisplayModel.empty(for: .englishToChinese),
            SubtitleDisplayModel(
                stablePrimaryLines: [],
                activePrimaryText: "",
                referenceText: "",
                targetLanguage: "Chinese",
                sourceLanguage: "English",
                isProcessing: false
            )
        )
    }

    func testRepeatedSegmentReadsReuseMaterializedArrayStorage() {
        let model = SubtitleDisplayModel(
            stablePrimaryLines: ["one", "two"],
            activePrimaryText: "three",
            referenceText: "source",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )

        let first = model.primarySegments.withUnsafeBufferPointer { $0.baseAddress }
        let second = model.primarySegments.withUnsafeBufferPointer { $0.baseAddress }
        XCTAssertEqual(first, second)
    }
}
