import XCTest
@testable import VoxHaloKit

final class AsrContextTermsParserTests: XCTestCase {
    func testEmptyInputProducesAnExplicitEmptyList() throws {
        for raw in [nil, "", "  \r\n\t,，  "] as [String?] {
            XCTAssertEqual(try AsrContextTermsParser.parse(raw), [])
        }
    }

    func testSeparatorsAndCaseInsensitiveDuplicatesPreserveFirstSpellingAndOrder() throws {
        let terms = try AsrContextTermsParser.parse(
            "  Elisha, Qwen3-ASR\r\nelisha，U.S.  "
        )

        XCTAssertEqual(terms, ["Elisha", "Qwen3-ASR", "U.S."])
    }

    func testSentencePunctuationIsRejected() {
        for raw in ["whole sentence!", "生僻词。", "term:semicolon", "Dr."] {
            XCTAssertThrowsError(try AsrContextTermsParser.parse(raw)) { error in
                XCTAssertTrue(error.localizedDescription.contains("punctuation"), raw)
            }
        }
    }

    func testDottedInitialismsAndInternalPeriodsAreAllowed() throws {
        XCTAssertEqual(
            try AsrContextTermsParser.parse("U.S. U.K. Node.js v1.2"),
            ["U.S.", "U.K.", "Node.js", "v1.2"]
        )
    }

    func testMoreThanTwentyFourTermsIsRejectedWithoutTruncation() {
        let raw = (1 ... 25).map { "term\($0)" }.joined(separator: " ")

        XCTAssertThrowsError(try AsrContextTermsParser.parse(raw)) { error in
            XCTAssertTrue(error.localizedDescription.contains("24"))
        }
    }

    func testExactlyOneHundredSixtyJoinedCharactersIsAllowed() throws {
        let raw = String(repeating: "A", count: 80)
            + " "
            + String(repeating: "B", count: 79)

        XCTAssertEqual(try AsrContextTermsParser.parse(raw).count, 2)
    }

    func testMoreThanOneHundredSixtyJoinedCharactersIsRejected() {
        let raw = String(repeating: "A", count: 80)
            + " "
            + String(repeating: "B", count: 80)

        XCTAssertThrowsError(try AsrContextTermsParser.parse(raw)) { error in
            XCTAssertTrue(error.localizedDescription.contains("160"))
        }
    }

    func testCharacterLimitCountsUnicodeScalarsLikeTheBackend() throws {
        let exactlyAtLimit = String(repeating: "𠮷", count: 160)
        let overLimit = exactlyAtLimit + "𠮷"

        XCTAssertEqual(
            try AsrContextTermsParser.parse(exactlyAtLimit),
            [exactlyAtLimit]
        )
        XCTAssertThrowsError(try AsrContextTermsParser.parse(overLimit)) { error in
            XCTAssertTrue(error.localizedDescription.contains("160"))
        }
    }
}
