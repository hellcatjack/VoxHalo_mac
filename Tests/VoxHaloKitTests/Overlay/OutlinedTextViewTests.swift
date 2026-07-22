import AppKit
import CoreText
import XCTest
@testable import VoxHaloKit

@MainActor
final class OutlinedTextViewTests: XCTestCase {
    func testViewIsFlippedNoninteractiveAndUsesVectorStrokeAttributes() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 160)
        )
        view.text = "In the beginning was the Word."
        view.textFont = .systemFont(ofSize: 38, weight: .semibold)
        view.textColor = .white
        view.outlineColor = NSColor.black.withAlphaComponent(0.9)
        view.outlineWidth = 1.8

        view.prepareLayoutCache()

        XCTAssertTrue(view.isFlipped)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(view.wantsLayer)
        XCTAssertNil(view.layer)

        let attributed = try XCTUnwrap(view.cachedAttributedText)
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .white)
        XCTAssertEqual(
            attributes[.strokeColor] as? NSColor,
            view.outlineColor
        )
        XCTAssertLessThan(try XCTUnwrap(attributes[.strokeWidth] as? CGFloat), 0)
        XCTAssertNil(attributes[.backgroundColor])
        let paragraph = try XCTUnwrap(
            attributes[.paragraphStyle] as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertEqual(paragraph.lineBreakMode, .byWordWrapping)
    }

    func testUnchangedContentFontBoundsAndColorsReuseFramesetterAndPath() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 140)
        )
        view.text = "Repeated subtitle text should reuse CoreText layout."
        view.prepareLayoutCache()
        let firstFramesetter = try XCTUnwrap(view.cachedFramesetterIdentity)
        let firstPath = try XCTUnwrap(view.cachedPathIdentity)
        let firstBuildCount = view.cacheBuildCount

        view.text = "Repeated subtitle text should reuse CoreText layout."
        view.textFont = view.textFont
        view.textColor = view.textColor
        view.outlineColor = view.outlineColor
        view.outlineWidth = view.outlineWidth
        view.prepareLayoutCache()

        XCTAssertEqual(view.cachedFramesetterIdentity, firstFramesetter)
        XCTAssertEqual(view.cachedPathIdentity, firstPath)
        XCTAssertEqual(view.cacheBuildCount, firstBuildCount)

        view.frame.size.width = 500
        view.prepareLayoutCache()
        XCTAssertNotEqual(view.cachedFramesetterIdentity, firstFramesetter)
        XCTAssertGreaterThan(view.cacheBuildCount, firstBuildCount)
    }

    func testTextChangeAdvancesContentGenerationAndWrapsToWidth() {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 80)
        )
        view.textFont = .systemFont(ofSize: 28, weight: .semibold)
        view.text = String(repeating: "wrapped words ", count: 20)

        let height = view.heightThatFits(width: 180)

        XCTAssertEqual(view.contentGeneration, 1)
        XCTAssertGreaterThan(height, view.textFont.pointSize * 2)
        view.text = "replacement"
        XCTAssertEqual(view.contentGeneration, 2)
    }
}
