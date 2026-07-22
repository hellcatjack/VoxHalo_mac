import XCTest
@testable import VoxHaloKit

final class VoxBridgeEventParserTests: XCTestCase {
    func testParserReadsEveryWireFieldAndNestedStability() throws {
        let json = #"{"type":"partial","sentence_id":"s1","text":"你好","state_text":"state","delta_text":"delta","text_reset":true,"tentative_text":"tent","committed_text":"done","translation":"hello","language":"Chinese","message":"m","reason":"r","translation_direction":"zh2en","translation_source_language":"Chinese","translation_target_language":"English","seq":7,"sample_rate":16000,"ts_ms":1234,"slice_commit":true,"is_stable":false,"stability":{"is_stable":true,"phase":"final","reason":"endpoint","sentence_id":"s1","segment_id":2,"seq":7,"committed_count":3,"tentative_chars":4,"unstable_chars":5}}"#

        let event = try VoxBridgeEventParser.parse(Data(json.utf8))

        XCTAssertEqual(event.type, .partial)
        XCTAssertEqual(event.rawType, "partial")
        XCTAssertEqual(event.sentenceID, "s1")
        XCTAssertEqual(event.text, "你好")
        XCTAssertEqual(event.stateText, "state")
        XCTAssertEqual(event.deltaText, "delta")
        XCTAssertEqual(event.textReset, true)
        XCTAssertEqual(event.tentativeText, "tent")
        XCTAssertEqual(event.committedText, "done")
        XCTAssertEqual(event.translation, "hello")
        XCTAssertEqual(event.language, "Chinese")
        XCTAssertEqual(event.message, "m")
        XCTAssertEqual(event.reason, "r")
        XCTAssertEqual(event.translationDirection, "zh2en")
        XCTAssertEqual(event.translationSourceLanguage, "Chinese")
        XCTAssertEqual(event.translationTargetLanguage, "English")
        XCTAssertEqual(event.sequence, 7)
        XCTAssertEqual(event.sampleRate, 16_000)
        XCTAssertEqual(event.timestampMilliseconds, 1_234)
        XCTAssertEqual(event.sliceCommit, true)
        XCTAssertEqual(event.isStable, false)
        XCTAssertEqual(event.stability, VoxBridgeStability(
            isStable: true,
            phase: "final",
            reason: "endpoint",
            sentenceID: "s1",
            segmentID: 2,
            sequence: 7,
            committedCount: 3,
            tentativeCharacters: 4,
            unstableCharacters: 5
        ))
    }

    func testEveryKnownEventTypeMapsExactly() throws {
        let values: [(String, VoxBridgeEventType)] = [
            ("ready", .ready),
            ("started", .started),
            ("partial", .partial),
            ("sentence_committed", .sentenceCommitted),
            ("sentence_updated", .sentenceUpdated),
            ("sentence_translation", .sentenceTranslation),
            ("sentence_reset", .sentenceReset),
            ("translation_direction", .translationDirection),
            ("processing", .processing),
            ("final", .final),
            ("error", .error),
            ("pong", .pong)
        ]

        for (rawValue, expected) in values {
            let event = try VoxBridgeEventParser.parse(#"{"type":"\#(rawValue)"}"#)
            XCTAssertEqual(event.type, expected, rawValue)
            XCTAssertEqual(event.rawType, rawValue)
        }
    }

    func testStartedEventParsesHotwordContextMetadata() throws {
        let event = try VoxBridgeEventParser.parse(
            #"{"type":"started","asr_context_active":true,"asr_context_term_count":2,"asr_context_chars":17}"#
        )

        XCTAssertEqual(event.type, .started)
        XCTAssertEqual(event.asrContextActive, true)
        XCTAssertEqual(event.asrContextTermCount, 2)
        XCTAssertEqual(event.asrContextCharacters, 17)
    }

    func testUnknownAndMissingTypesArePreservedAsUnknown() throws {
        let future = try VoxBridgeEventParser.parse(#"{"type":"future_event","seq":9}"#)
        XCTAssertEqual(future.type, .unknown)
        XCTAssertEqual(future.rawType, "future_event")
        XCTAssertEqual(future.sequence, 9)

        let missing = try VoxBridgeEventParser.parse(#"{"text":"still usable"}"#)
        XCTAssertEqual(missing.type, .unknown)
        XCTAssertEqual(missing.rawType, "")
        XCTAssertEqual(missing.text, "still usable")
    }

    func testWrongTypedOptionalFieldsBecomeNilWithoutCoercion() throws {
        let event = try VoxBridgeEventParser.parse(
            #"{"type":"partial","text":42,"seq":"7","sample_rate":true,"ts_ms":1.5,"slice_commit":"true","stability":[]}"#
        )

        XCTAssertNil(event.text)
        XCTAssertNil(event.sequence)
        XCTAssertNil(event.sampleRate)
        XCTAssertNil(event.timestampMilliseconds)
        XCTAssertNil(event.sliceCommit)
        XCTAssertNil(event.stability)
    }

    func testMalformedJSONAndNonObjectRootThrow() {
        XCTAssertThrowsError(try VoxBridgeEventParser.parse("{"))
        XCTAssertThrowsError(try VoxBridgeEventParser.parse("[]"))
    }

    func testUTF8DataPathPreservesChineseWithoutStringPreconversion() throws {
        let data = Data(#"{"type":"sentence_translation","sentence_id":"s1","translation":"世界你好"}"#.utf8)
        let event = try VoxBridgeEventParser.parse(data)

        XCTAssertEqual(event.type, .sentenceTranslation)
        XCTAssertEqual(event.translation, "世界你好")
    }
}
