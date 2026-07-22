import XCTest
@testable import VoxHaloKit

final class SubtitleStateStoreResetAndBoundsTests: XCTestCase {
    func testOrdinaryResetStillClearsImmediately() {
        var store = makeTranslatedStore((
            "s1",
            "Source before ordinary reset.",
            "Translation before ordinary reset."
        ))

        store.apply(.reset(reason: "new_stream"))

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.current, .empty(for: .englishToChinese))
    }

    func testFinalRedecodeResetKeepsVisibleSnapshotUntilAtomicFinalReplacement() {
        var store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "神爱世人", "God loves the world")
        )
        store.apply(.reset(reason: "final_redecode"))

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.current.primaryText, "God loves the world")

        store.apply(.final(
            text: "神爱世人。",
            translation: "God so loved the world.",
            sequence: 10
        ))
        XCTAssertEqual(store.current.primaryText, "God so loved the world.")
    }

    func testFinalCommitReconcileResetKeepsVisibleSnapshotDuringRebuild() {
        var store = makeTranslatedStore(
            ("s1", "Opening source.", "Opening translation."),
            ("s2", "Middle source.", "Middle translation."),
            ("s3", "Tail source.", "Tail translation.")
        )
        store.apply(.reset(reason: "final_commit_reconcile"))

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(
            store.current.primaryText,
            "Opening translation. Middle translation. Tail translation."
        )
        XCTAssertEqual(store.current.referenceText, "Tail source.")
    }

    func testFinalCommitReplayBuildsOnlyCanonicalRows() {
        var store = makeTranslatedStore(
            ("s1", "Opening source.", "Opening translation."),
            ("s2", "Tail source one.", "Old tail translation one."),
            ("s3", "Tail source two.", "Old tail translation two.")
        )
        store.apply(.reset(reason: "final_commit_reconcile"))
        addTranslatedSentence(&store, id: "r1", source: "Tail source one.",
                              translation: "Reconciled tail translation one.", sequence: 7)
        XCTAssertEqual(
            store.current.primaryText,
            "Opening translation. Old tail translation one. Old tail translation two."
        )
        addTranslatedSentence(&store, id: "r2", source: "Tail source two.",
                              translation: "Reconciled tail translation two.", sequence: 9)
        XCTAssertEqual(
            store.current.primaryText,
            "Opening translation. Old tail translation one. Old tail translation two."
        )
        store.apply(.final(
            translation: "Reconciled tail translation one. Reconciled tail translation two.",
            sequence: 11
        ))

        XCTAssertEqual(store.current.primarySegments,
                       ["Reconciled tail translation one.", "Reconciled tail translation two."])
        XCTAssertEqual(store.rows.map(\.sentenceID), ["r1", "r2"])
    }

    func testPrimaryTextNeverDropsACharacterInsideRetainedSegments() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...4 {
            addTranslatedSentence(
                &store,
                id: "s\(index)",
                source: "Source \(index)",
                translation: "Translation \(index) " + String(repeating: "x", count: 90),
                sequence: index * 2
            )
        }

        XCTAssertTrue(store.current.primaryText.hasPrefix(
            "Translation 1 " + String(repeating: "x", count: 90)
        ))
        XCTAssertFalse(store.current.primaryText.hasPrefix("..."))
        XCTAssertTrue(store.current.primaryText.hasSuffix(
            "Translation 4 " + String(repeating: "x", count: 90)
        ))
    }

    func testTargetKeepsTwoMinuteHistoryWhileReferenceKeepsNewest24Segments() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...30 {
            addTranslatedSentence(&store, id: "s\(index)", source: "Source \(index)",
                                  translation: "Translation \(index)", sequence: index * 2)
        }

        XCTAssertEqual(store.current.primarySegments.count, 30)
        XCTAssertEqual(store.current.primarySegments.first, "Translation 1")
        XCTAssertEqual(store.current.referenceSegments.count, 24)
        XCTAssertEqual(store.current.referenceSegments.first, "Source 7")
    }

    func testLongSessionTargetHistoryRemainsBoundedAtWholeSentenceBoundary() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...110 {
            addTranslatedSentence(
                &store,
                id: "s\(index)",
                source: "Source \(index)",
                translation: "Translation \(index)",
                sequence: index * 2
            )
        }

        XCTAssertEqual(store.current.primarySegments.count, 96)
        XCTAssertEqual(store.current.primarySegments.first, "Translation 15")
        XCTAssertEqual(store.current.referenceSegments.count, 24)
        XCTAssertEqual(store.current.referenceSegments.first, "Source 87")
        XCTAssertFalse(store.current.primaryText.hasPrefix("..."))
    }

    func testProcessingTurnsOnAndFinalTurnsItOff() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.processing())
        XCTAssertTrue(store.current.isProcessing)

        store.apply(.final())
        XCTAssertFalse(store.current.isProcessing)
    }

    func testDirectionResetClearsStateAndChangesLabels() {
        var store = makeTranslatedStore(("s1", "Source", "Translation"))
        store.reset(direction: .chineseToEnglish)

        XCTAssertEqual(store.current, .empty(for: .chineseToEnglish))
        XCTAssertTrue(store.rows.isEmpty)
    }
}
