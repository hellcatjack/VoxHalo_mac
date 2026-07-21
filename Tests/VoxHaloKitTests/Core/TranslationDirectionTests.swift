import XCTest
@testable import VoxHaloKit

final class TranslationDirectionTests: XCTestCase {
    func testChineseToEnglishMapsToWireAndDisplayValues() {
        let direction = TranslationDirection.chineseToEnglish

        XCTAssertEqual(direction.rawValue, 0)
        XCTAssertEqual(direction.backendLanguage, "Chinese")
        XCTAssertEqual(direction.backendDirection, "zh2en")
        XCTAssertEqual(direction.targetLanguageLabel, "English")
        XCTAssertEqual(direction.sourceLanguageLabel, "Chinese")
    }

    func testEnglishToChineseMapsToWireAndDisplayValues() {
        let direction = TranslationDirection.englishToChinese

        XCTAssertEqual(direction.rawValue, 1)
        XCTAssertEqual(direction.backendLanguage, "English")
        XCTAssertEqual(direction.backendDirection, "en2zh")
        XCTAssertEqual(direction.targetLanguageLabel, "Chinese")
        XCTAssertEqual(direction.sourceLanguageLabel, "English")
    }
}
