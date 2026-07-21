import XCTest
@testable import VoxHaloKit

final class SubtitleStateStoreTranslationTests: XCTestCase {
    func testTranslationBecomesPrimaryText() {
        var store = SubtitleStateStore(direction: .chineseToEnglish)
        store.apply(.committed("s1", "神是良善的", sequence: 1))
        store.apply(.translated("s1", "God is good", sequence: 2))

        XCTAssertEqual(store.current.primaryText, "God is good")
        XCTAssertEqual(store.current.referenceText, "神是良善的")
        XCTAssertEqual(store.current.targetLanguage, "English")
        XCTAssertEqual(store.current.sourceLanguage, "Chinese")
    }

    func testHistoricalSourceUpdateDoesNotReplaceLatestRecognizedSentence() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.committed("s1", "First recognized sentence.", sequence: 1))
        store.apply(.committed("s2", "Second recognized sentence.", sequence: 2))
        store.apply(.updated("s1", "Corrected first recognized sentence.", sequence: 3))

        XCTAssertEqual(store.current.referenceText, "Second recognized sentence.")
    }

    func testSentenceUpdatePreservesDisplayedTranslation() {
        var store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "旧文本", "Old text")
        )
        store.apply(.updated("s1", "新文本", sequence: 3))

        XCTAssertEqual(store.current.primaryText, "Old text")
        XCTAssertEqual(store.current.referenceText, "新文本")
    }

    func testTranslationArrivingBeforeSourceIsDisplayedAndPreserved() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.translated("s1", "Translation one", sequence: 2))
        XCTAssertEqual(store.current.primarySegments, ["Translation one"])
        XCTAssertEqual(store.current.referenceText, "")

        store.apply(.committed("s1", "Source one.", sequence: 1))
        XCTAssertEqual(store.current.primarySegments, ["Translation one"])
        XCTAssertEqual(store.current.referenceText, "Source one.")
        XCTAssertEqual(store.rows[0].sequence, 2)
    }

    func testSentenceUpdateKeepsTranslationUntilReplacementArrives() {
        var store = makeTranslatedStore(("s1", "Old source", "Old translation"))
        store.apply(.updated("s1", "Corrected source", sequence: 3))
        XCTAssertEqual(store.current.activePrimaryText, "Old translation")

        store.apply(.translated("s1", "Corrected translation", sequence: 4))
        XCTAssertEqual(store.current.primarySegments, ["Corrected translation"])
    }

    func testPrimaryTextShowsTranslationsAsContinuousStream() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...4 {
            addTranslatedSentence(
                &store,
                id: "s\(index)",
                source: "Source \(index)",
                translation: "Translation \(index)",
                sequence: index * 2 - 1
            )
        }

        XCTAssertEqual(store.current.primaryText,
                       "Translation 1 Translation 2 Translation 3 Translation 4")
        XCTAssertFalse(store.current.primaryText.contains("\n"))
        XCTAssertEqual(store.current.referenceText, "Source 4")
    }

    func testRepeatedTranslationUpdatesActiveWithoutStableHistory() {
        var store = makeTranslatedStore(("s1", "In the beginning", "In the beginning"))
        store.apply(.translated("s1", "In the beginning God created", sequence: 3))

        XCTAssertEqual(store.current.stablePrimaryText, "")
        XCTAssertEqual(store.current.activePrimaryText, "In the beginning God created")
    }

    func testNewSentenceFinalizesPreviousActiveIntoStableHistory() {
        let store = makeTranslatedStore(
            ("s1", "First source", "First translation"),
            ("s2", "Second source", "Second translation")
        )

        XCTAssertEqual(store.current.stablePrimaryText, "First translation")
        XCTAssertEqual(store.current.activePrimaryText, "Second translation")
        XCTAssertEqual(store.current.primaryText, "First translation Second translation")
    }

    func testOutOfOrderTranslationsFillInsertionTimeline() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        store.apply(.committed("s1", "First source", sequence: 1))
        store.apply(.committed("s2", "Second source", sequence: 2))
        store.apply(.committed("s3", "Third source", sequence: 3))
        store.apply(.translated("s1", "First translation", sequence: 4))
        store.apply(.translated("s3", "Third translation", sequence: 6))
        store.apply(.translated("s2", "Second translation", sequence: 5))

        XCTAssertEqual(store.current.primarySegments,
                       ["First translation", "Second translation", "Third translation"])
        XCTAssertEqual(store.current.stablePrimaryText,
                       "First translation Second translation")
        XCTAssertEqual(store.current.activePrimaryText, "Third translation")
    }

    func testStableHistoryKeepsDisplayedSentencesWhenActiveAdvances() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...4 {
            addTranslatedSentence(&store, id: "s\(index)", source: "Source \(index)",
                                  translation: "Translation \(index)", sequence: index * 2)
        }
        XCTAssertEqual(store.current.stablePrimaryText,
                       "Translation 1 Translation 2 Translation 3")
        XCTAssertEqual(store.current.activePrimaryText, "Translation 4")
    }

    func testStableHistoryRetainsDisplayedSentencesForVerticalScroll() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        for index in 1...6 {
            addTranslatedSentence(&store, id: "s\(index)", source: "Source \(index)",
                                  translation: "Translation \(index)", sequence: index * 2)
        }
        XCTAssertEqual(store.current.primarySegments, (1...6).map { "Translation \($0)" })
    }

    func testHistoricalTranslationWithoutSourceUpdateDoesNotRewriteDisplay() {
        var store = makeTranslatedStore(
            ("s1", "First source", "First translation"),
            ("s2", "Second source", "Second translation")
        )
        store.apply(.translated("s1", "Unrequested corrected first translation", sequence: 6))

        XCTAssertEqual(store.rows[0].translation, "Unrequested corrected first translation")
        XCTAssertEqual(store.current.primarySegments,
                       ["First translation", "Second translation"])
    }

    func testHistoricalSentenceUpdateAuthorizesReplacementTranslation() {
        var store = makeTranslatedStore(
            ("s1", "Elijah said stay here.", "Elijah said stay here."),
            ("s2", "They went on.", "They went on.")
        )
        store.apply(.updated(
            "s1",
            "Elijah said, please stay here, for the Lord has sent me to the Jordan.",
            sequence: 5
        ))
        store.apply(.translated(
            "s1",
            "Elijah said, please stay here, for the Lord has sent me to the Jordan.",
            sequence: 6
        ))

        XCTAssertEqual(store.current.primarySegments, [
            "Elijah said, please stay here, for the Lord has sent me to the Jordan.",
            "They went on."
        ])
    }

    func testStableChineseTranslationIsDisplayedWithoutLocalHoldback() {
        var store = SubtitleStateStore(direction: .chineseToEnglish)
        store.apply(.committed(
            "s1",
            "说他接下来是说：“弟兄姐妹，我。”",
            sequence: 1,
            isStable: true,
            stability: VoxBridgeStability(
                isStable: true,
                phase: "solidified",
                reason: "sentence_committed",
                sentenceID: "s1",
                sequence: 1
            )
        ))
        store.apply(.translated(
            "s1",
            "He then said, \"Brothers and sisters, I.\"",
            sequence: 2
        ))
        XCTAssertEqual(store.current.primaryText,
                       "He then said, \"Brothers and sisters, I.\"")

        store.apply(.updated("s1", "说他接下来是说：“弟兄姐妹，我是说时候不多了。”", sequence: 3))
        store.apply(.translated(
            "s1",
            "He then said, \"Brothers and sisters, I mean the time is short.\"",
            sequence: 4
        ))
        XCTAssertEqual(store.current.primaryText,
                       "He then said, \"Brothers and sisters, I mean the time is short.\"")
    }

    func testChineseSentenceEndingWithObjectPronounIsDisplayed() {
        let store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "在极度艰难的时期，你的家人比以往任何时间都更需要你。",
             "During these extremely difficult times, your family needs you more than ever before.")
        )
        XCTAssertEqual(store.current.primaryText,
                       "During these extremely difficult times, your family needs you more than ever before.")
    }

    func testChineseSentenceEndingWithCompoundDuiIsDisplayed() {
        let store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "当你独自一人被送到罗马斗兽场，你可以勇敢地面对。",
             "When you are sent alone to the Colosseum in Rome, you can face it bravely.")
        )
        XCTAssertEqual(store.current.primaryText,
                       "When you are sent alone to the Colosseum in Rome, you can face it bravely.")
    }

    func testChineseSentenceEndingWithCompoundLaiIsDisplayed() {
        let store = makeTranslatedStore(
            direction: .chineseToEnglish,
            ("s1", "提醒所有的基督徒：无论是单身的，或是已婚的，都要准备好在主的再来。",
             "Remind all Christians: whether single or married, everyone must be prepared for the coming of the Lord.")
        )
        XCTAssertEqual(store.current.primaryText,
                       "Remind all Christians: whether single or married, everyone must be prepared for the coming of the Lord.")
    }
}
