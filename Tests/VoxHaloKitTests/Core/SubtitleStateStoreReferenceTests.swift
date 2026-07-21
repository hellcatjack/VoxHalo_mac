import XCTest
@testable import VoxHaloKit

final class SubtitleStateStoreReferenceTests: XCTestCase {
    func testPartialUpdatesReferenceWithoutChangingTranslation() {
        var store = makeTranslatedStore(("s1", "God is good.", "神是良善的。"))
        store.apply(.partial(tentative: "God is good. All the time", sequence: 3))

        XCTAssertEqual(store.current.primaryText, "神是良善的。")
        XCTAssertEqual(store.current.referenceText, "All the time")
    }

    func testPartialBeforeCommitShowsTentativeImmediately() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.partial(tentative: "God is good and"))
        XCTAssertEqual(store.current.referenceText, "God is good and")

        store.apply(.committed("s1", "God is good.", sequence: 2))
        XCTAssertEqual(store.current.referenceText, "God is good.")
    }

    func testReferenceSegmentsRetainRecognizedSentences() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...4 {
            store.apply(.committed("s\(index)", "Recognized sentence \(index).", sequence: index))
        }

        XCTAssertEqual(store.current.referenceText, "Recognized sentence 4.")
        XCTAssertEqual(store.current.referenceSegments, (1...4).map { "Recognized sentence \($0)." })
    }

    func testReferenceSegmentsAppendLivePartial() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.committed("s1", "Recognized sentence one.", sequence: 1))
        store.apply(.partial(tentative: "Recognized sentence two is still live", sequence: 2))

        XCTAssertEqual(store.current.referenceSegments,
                       ["Recognized sentence one.", "Recognized sentence two is still live"])
    }

    func testPartialChangesOnlyReferenceAndLeavesTargetStable() {
        var store = makeTranslatedStore(("s1", "God is good.", "God is good."))
        store.apply(.partial(tentative: "God is good. All the time", sequence: 3))

        XCTAssertEqual(store.current.stablePrimaryText, "")
        XCTAssertEqual(store.current.activePrimaryText, "God is good.")
        XCTAssertEqual(store.current.referenceText, "All the time")
    }

    func testPartialUsesTentativeAfterCommittedPrefix() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.partial(
            tentative: "Elijah and Elisha were on their way from Gilgal.",
            committed: "Now when the Lord was about to take Elijah up to heaven by a whirlwind,"
        ))

        XCTAssertEqual(store.current.referenceText,
                       "Elijah and Elisha were on their way from Gilgal.")
        XCTAssertEqual(store.current.primaryText, "")
    }

    func testTextResetTrustsBackendStateWithoutPrefixTrimming() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.partial(
            state: "First partial sentence that may reset.",
            tentative: "First partial sentence that may reset."
        ))
        store.apply(.partial(
            text: "Different corrected recognition after reset.",
            state: "Different corrected recognition after reset.",
            delta: "Different corrected recognition after reset.",
            reset: true,
            sequence: 2
        ))

        XCTAssertEqual(store.current.referenceText,
                       "Different corrected recognition after reset.")
    }

    func testShortTentativeAvoidsRebuildingLargeCommittedPrefix() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        let committed = Array(repeating: "already committed recognition history", count: 300)
            .joined(separator: " ")
        for sequence in 1...101 {
            store.apply(.partial(
                text: committed + " short live tail",
                tentative: "short live tail",
                committed: committed,
                sequence: sequence
            ))
        }

        XCTAssertEqual(store.current.referenceText, "short live tail")
    }

    func testReferenceOnlyBurstReusesTargetSegmentStorage() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...24 {
            addTranslatedSentence(
                &store,
                id: "s\(index)",
                source: "Recognized sentence \(index) with extra spacing.",
                translation: "Translated sentence \(index) with extra spacing.",
                sequence: index * 2
            )
        }
        let before = store.current.primarySegments.withUnsafeBufferPointer { $0.baseAddress }

        for index in 0..<100 {
            store.apply(.partial(tentative: "live recognition tail \(index)", sequence: 1_000 + index))
        }
        let after = store.current.primarySegments.withUnsafeBufferPointer { $0.baseAddress }

        XCTAssertEqual(store.current.primarySegments.count, 24)
        XCTAssertEqual(store.current.referenceSegments.count, 24)
        XCTAssertEqual(before, after)
    }
}
