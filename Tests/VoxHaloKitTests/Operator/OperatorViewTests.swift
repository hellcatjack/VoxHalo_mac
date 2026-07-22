import AppKit
import SwiftUI
import XCTest
@testable import VoxHaloKit

@MainActor
final class OperatorViewTests: XCTestCase {
    func testNativeOperatorViewRendersAsAWindowSizedSwiftUIView() throws {
        _ = NSApplication.shared
        let fixture = try OperatorFixture()
        let hostingView = NSHostingView(rootView: OperatorView(model: fixture.model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 500)
        XCTAssertGreaterThan(hostingView.fittingSize.height, 500)
    }

    func testViewDeclaresEveryRequiredNativeControl() {
        XCTAssertEqual(OperatorView.controlIdentifiers, Set([
            "operator.root",
            "operator.backend",
            "operator.username",
            "operator.password",
            "operator.direction",
            "operator.hotwords",
            "operator.audioSource",
            "operator.display",
            "operator.target.height",
            "operator.target.font",
            "operator.target.offset",
            "operator.target.color",
            "operator.reference.height",
            "operator.reference.font",
            "operator.reference.offset",
            "operator.reference.color",
            "operator.start",
            "operator.stop",
            "operator.status",
        ]))
    }

    func testViewExposesMultilineHotwordGuidanceAndSizing() {
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("spaces"))
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("commas"))
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("new lines"))
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("24"))
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("160"))
        XCTAssertTrue(OperatorView.hotwordGuidance.contains("Saved automatically"))
        XCTAssertGreaterThanOrEqual(OperatorView.hotwordEditorHeight, 64)
    }

    func testViewExposesExactLayoutRanges() {
        XCTAssertEqual(OperatorView.targetAreaHeightRange, 120 ... 640)
        XCTAssertEqual(OperatorView.targetFontSizeRange, 18 ... 56)
        XCTAssertEqual(OperatorView.targetTopOffsetRange, 0 ... 900)
        XCTAssertEqual(OperatorView.referenceAreaHeightRange, 48 ... 360)
        XCTAssertEqual(OperatorView.referenceFontSizeRange, 16 ... 42)
        XCTAssertEqual(OperatorView.referenceBottomOffsetRange, 0 ... 900)
    }

    func testViewModelContainsExactlyTwoDirectionChoicesAndSixColors() throws {
        let fixture = try OperatorFixture()

        XCTAssertEqual(fixture.model.directions.count, 2)
        XCTAssertEqual(fixture.model.colorChoices.count, 6)
        XCTAssertEqual(fixture.model.directionLabel(.chineseToEnglish), "Chinese → English")
        XCTAssertEqual(fixture.model.directionLabel(.englishToChinese), "English → Chinese")
    }

    func testInvalidEndpointDisablesStartWhileDisplayAndLayoutRemainEditable() throws {
        let fixture = try OperatorFixture()
        fixture.model.backendURL = "https://not-a-websocket.test"

        XCTAssertFalse(fixture.model.canStart)
        XCTAssertTrue(fixture.model.canEditDisplayAndLayout)
        XCTAssertTrue(fixture.model.canEditBackend)
    }
}
