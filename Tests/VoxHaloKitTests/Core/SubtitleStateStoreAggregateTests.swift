import XCTest
@testable import VoxHaloKit

final class SubtitleStateStoreAggregateTests: XCTestCase {
    func testPartialCommittedAggregateKeepsShortSentenceWhenLiveReferenceAdvances() {
        var store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "Opening source.", "Opening translation.")
        )
        store.apply(.partial(tentative: "Short phrase.", sequence: 3))
        store.apply(.partial(
            text: "Opening source. Short phrase. Next live phrase",
            tentative: "Next live phrase",
            committed: "Opening source. Short phrase.",
            translation: "Opening translation. Short phrase translation.",
            sequence: 4
        ))

        XCTAssertEqual(store.current.referenceSegments,
                       ["Opening source.", "Short phrase.", "Next live phrase"])
        XCTAssertEqual(store.current.primarySegments,
                       ["Opening translation.", "Short phrase translation."])
    }

    func testCanonicalSentenceEventsReplaceAggregateFallbackWithoutDuplication() {
        var store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "Opening source.", "Opening translation.")
        )
        store.apply(.partial(
            text: "Opening source. Short phrase. Next live phrase",
            tentative: "Next live phrase",
            committed: "Opening source. Short phrase.",
            translation: "Opening translation. Short phrase translation.",
            sequence: 3
        ))
        addTranslatedSentence(&store, id: "s2", source: "Short phrase.",
                              translation: "Short phrase translation.", sequence: 4)

        XCTAssertEqual(store.current.referenceSegments, ["Opening source.", "Short phrase."])
        XCTAssertEqual(store.current.primarySegments,
                       ["Opening translation.", "Short phrase translation."])
    }

    func testFinalAggregateDisplaysWhenSentenceTranslationIsMissing() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        let source = Array(repeating: "The king spoke a long sentence without a clean pause", count: 14)
            .joined(separator: " ")
        let translation = Array(repeating: "王说了一段很长但已经完成的句子", count: 14)
            .joined(separator: " ")
        store.apply(.final(text: source, translation: translation, sequence: 99))

        XCTAssertEqual(store.current.referenceText, source)
        XCTAssertEqual(store.current.primarySegments, [translation])
    }

    func testFinalDoesNotReplaceLatestCommittedReference() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.committed("s1", "The latest stable sentence.", sequence: 1))
        store.apply(.final(
            text: "The latest stable sentence. A final aggregate sentence that is much longer.",
            translation: "Final aggregate translation.",
            sequence: 2
        ))

        XCTAssertEqual(store.current.referenceText, "The latest stable sentence.")
    }

    func testPartialAggregateWithoutCommittedTextDoesNotAddTargetTail() {
        var store = makeTranslatedStore(
            ("s1", "First source.", "First stable translation."),
            ("s2", "Second source.", "Second stable translation.")
        )
        store.apply(.partial(
            translation: "First translation revised by backend. Second stable translation. Live partial translation appears sooner.",
            sequence: 5
        ))

        XCTAssertEqual(store.current.primarySegments,
                       ["First stable translation.", "Second stable translation."])
    }

    func testPartialTranslationBeforeSentenceTranslationDoesNotShowTarget() {
        var store = SubtitleStateStore(direction: .chineseToEnglish)
        store.apply(.partial(
            text: "当你独自一人被送到罗马斗兽。",
            tentative: "当你独自一人被送到罗马斗兽。",
            translation: "When you are sent alone to the Roman arena.",
            sequence: 28
        ))

        XCTAssertEqual(store.current.primaryText, "")
        XCTAssertEqual(store.current.referenceText, "当你独自一人被送到罗马斗兽。")
    }

    func testUnrelatedCommittedAggregateCannotRewriteStructuredTarget() {
        var store = makeTranslatedStore(("s1", "你好", "hello"))
        store.apply(.partial(
            tentative: "世界",
            committed: "你好",
            translation: "unrelated live tail"
        ))
        XCTAssertEqual(store.current.primarySegments, ["hello"])
    }
}
