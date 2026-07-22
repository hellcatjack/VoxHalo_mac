import AppKit
import CoreText
import XCTest
@testable import VoxHaloKit

@MainActor
final class OutlinedTextViewTests: XCTestCase {
    func testViewIsFlippedNoninteractiveAndUsesLayeredVectorStroke() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 160)
        )
        view.text = "In the beginning was the Word."
        view.textFont = .systemFont(ofSize: 38, weight: .semibold)
        view.textColor = .white
        view.outlineColor = NSColor.black.withAlphaComponent(0.9)
        view.outlineWidth = 1.8
        view.outlineShadowColor = NSColor.black.withAlphaComponent(0.9)
        view.outlineShadowBlur = 2.5

        view.prepareLayoutCache()

        XCTAssertTrue(view.isFlipped)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertFalse(view.wantsLayer)
        XCTAssertNil(view.layer)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertEqual(
            view.accessibilityValue() as? String,
            "In the beginning was the Word."
        )

        let fill = try XCTUnwrap(view.cachedAttributedText)
        let fillAttributes = fill.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(fillAttributes[.foregroundColor] as? NSColor, .white)
        XCTAssertNil(fillAttributes[.strokeColor])
        XCTAssertNil(fillAttributes[.strokeWidth])

        let outline = try XCTUnwrap(view.cachedOutlineAttributedText)
        let outlineAttributes = outline.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(
            outlineAttributes[.strokeColor] as? NSColor,
            view.outlineColor
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(outlineAttributes[.strokeWidth] as? CGFloat),
            0
        )
        XCTAssertGreaterThan(view.outlineShadowBlur, view.outlineWidth)
        let shadowColor = try XCTUnwrap(
            view.outlineShadowColor.usingColorSpace(.deviceRGB)
        )
        XCTAssertEqual(shadowColor.alphaComponent, 0.9, accuracy: 0.001)
        XCTAssertNil(fillAttributes[.backgroundColor])
        let paragraph = try XCTUnwrap(
            fillAttributes[.paragraphStyle] as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertEqual(paragraph.lineBreakMode, .byWordWrapping)
        let naturalHeight = view.textFont.ascender
            - view.textFont.descender
            + max(0, view.textFont.leading)
        XCTAssertGreaterThanOrEqual(
            paragraph.minimumLineHeight,
            ceil(naturalHeight * 1.06)
        )
        XCTAssertEqual(view.layoutLineHeight, paragraph.minimumLineHeight)
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
        view.outlineShadowColor = view.outlineShadowColor
        view.outlineShadowBlur = view.outlineShadowBlur
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

    func testShadowPropertiesNormalizeWithoutRebuildingTextLayout() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 120)
        )
        view.text = "High contrast subtitle"
        view.prepareLayoutCache()
        let framesetter = try XCTUnwrap(view.cachedFramesetterIdentity)
        let buildCount = view.cacheBuildCount

        view.outlineShadowColor = NSColor.black.withAlphaComponent(0.75)
        view.outlineShadowBlur = .nan
        view.prepareLayoutCache()

        XCTAssertEqual(view.outlineShadowBlur, 0)
        XCTAssertEqual(view.cachedFramesetterIdentity, framesetter)
        XCTAssertEqual(view.cacheBuildCount, buildCount)
    }

    func testLatestSuffixUsesDistinctFillWithoutSplittingUnicode() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 140)
        )
        let historyColor = NSColor(white: 0.72, alpha: 1)
        view.textColor = .white
        view.historyTextColor = historyColor
        view.setText(
            "Earlier translation. 最新🚀翻译。",
            latestText: "最新🚀翻译。"
        )
        view.prepareLayoutCache()

        let fill = try XCTUnwrap(view.cachedAttributedText)
        let latestRange = (fill.string as NSString).range(of: "最新🚀翻译。")
        XCTAssertNotEqual(latestRange.location, NSNotFound)
        XCTAssertEqual(
            fill.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor,
            historyColor
        )
        XCTAssertEqual(
            fill.attribute(
                .foregroundColor,
                at: latestRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .white
        )

        let outline = try XCTUnwrap(view.cachedOutlineAttributedText)
        XCTAssertEqual(
            outline.attribute(
                .foregroundColor,
                at: latestRange.location,
                effectiveRange: nil
            ) as? NSColor,
            .white
        )
        XCTAssertEqual(view.contentGeneration, 1)
    }

    func testChangingOnlyLatestBoundaryRebuildsStyleNotContentGeneration() throws {
        let view = OutlinedTextView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 140)
        )
        view.historyTextColor = NSColor(white: 0.75, alpha: 1)
        view.setText("first sentence second sentence", latestText: "second sentence")
        view.prepareLayoutCache()
        let firstIdentity = try XCTUnwrap(view.cachedFramesetterIdentity)
        let contentGeneration = view.contentGeneration

        view.latestText = ""
        view.prepareLayoutCache()

        XCTAssertEqual(view.contentGeneration, contentGeneration)
        XCTAssertNotEqual(view.cachedFramesetterIdentity, firstIdentity)
        let fill = try XCTUnwrap(view.cachedAttributedText)
        XCTAssertEqual(
            fill.attribute(
                .foregroundColor,
                at: (fill.string as NSString).length - 1,
                effectiveRange: nil
            ) as? NSColor,
            view.historyTextColor
        )
    }
}
