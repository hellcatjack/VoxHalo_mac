import XCTest
@testable import VoxHaloKit

final class VoxBridgeMessagesTests: XCTestCase {
    func testChineseToEnglishStartMessageUsesExactProtocolNames() throws {
        XCTAssertEqual(
            try text(VoxBridgeMessageEncoder.start(.chineseToEnglish)),
            #"{"language":"Chinese","translation_direction":"zh2en","type":"start"}"#
        )
    }

    func testEnglishToChineseStartMessageUsesExactProtocolNames() throws {
        XCTAssertEqual(
            try text(VoxBridgeMessageEncoder.start(.englishToChinese)),
            #"{"language":"English","translation_direction":"en2zh","type":"start"}"#
        )
    }

    func testDirectionChangeAndFinishMessagesAreExact() throws {
        XCTAssertEqual(
            try text(VoxBridgeMessageEncoder.setTranslationDirection(.englishToChinese)),
            #"{"translation_direction":"en2zh","type":"set_translation_direction"}"#
        )
        XCTAssertEqual(try text(VoxBridgeMessageEncoder.finish()), #"{"type":"finish"}"#)
    }

    private func text(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
