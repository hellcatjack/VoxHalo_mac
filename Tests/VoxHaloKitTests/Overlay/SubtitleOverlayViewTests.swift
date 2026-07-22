import AppKit
import XCTest
@testable import VoxHaloKit

@MainActor
final class SubtitleOverlayViewTests: XCTestCase {
    func testLayoutKeepsTargetNearTopAndReferenceNearBottom() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        view.apply(layout: .defaults, display: display())
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            view.targetRegion.frame.minY,
            view.referenceRegion.frame.maxY
        )
        XCTAssertEqual(view.targetRegion.frame.height, 264)
        XCTAssertEqual(view.referenceRegion.frame.height, 96)
        XCTAssertEqual(view.targetRegion.frame.minX, 64)
        XCTAssertEqual(view.targetRegion.frame.width, 1_312)
        XCTAssertEqual(view.targetTextView.alignment, .left)
        XCTAssertEqual(view.referenceTextView.alignment, .left)
        XCTAssertGreaterThan(
            view.targetTextView.textFont.pointSize,
            view.referenceTextView.textFont.pointSize
        )
        XCTAssertEqual(
            view.targetTextView.textFont.fontName,
            "PingFangSC-Semibold"
        )
        XCTAssertEqual(
            view.referenceTextView.textFont.fontName,
            "PingFangSC-Medium"
        )
        XCTAssertEqual(view.targetTextView.outlineWidth, 1.0)
        XCTAssertEqual(view.referenceTextView.outlineWidth, 0.85)
    }

    func testLayoutClampsEveryDimensionBeforeComputingNonoverlappingFrames() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let extreme = SubtitleLayoutSettings(
            targetAreaHeight: 10_000,
            targetFontSize: 500,
            targetTopOffset: 10_000,
            targetColor: "#FFD966",
            referenceAreaHeight: 10_000,
            referenceFontSize: 1,
            referenceBottomOffset: 10_000,
            referenceColor: "#8FE8FF"
        )

        view.apply(layout: extreme, display: display(width: 800, height: 600))
        view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(view.targetRegion.frame.height, 640)
        XCTAssertLessThanOrEqual(view.referenceRegion.frame.height, 360)
        XCTAssertLessThanOrEqual(
            view.referenceRegion.frame.maxY,
            view.targetRegion.frame.minY
        )
        XCTAssertTrue(view.bounds.contains(view.targetRegion.frame))
        XCTAssertTrue(view.bounds.contains(view.referenceRegion.frame))
        XCTAssertEqual(view.targetTextView.textFont.pointSize, 56)
        XCTAssertEqual(view.referenceTextView.textFont.pointSize, 16)
        XCTAssertEqual(view.targetTextView.textColor.hexRGB, "#FFD966")
        XCTAssertEqual(view.referenceTextView.textColor.hexRGB, "#8FE8FF")
    }

    func testTargetIsOneContinuousBlockAndReferenceUsesBoundedSegments() {
        let view = makeView()
        let model = SubtitleDisplayModel(
            stablePrimaryLines: ["first", "second"],
            activePrimaryText: "third",
            referenceText: "live",
            referenceSegments: ["source one", "source two"],
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: true
        )

        view.apply(model: model)

        XCTAssertEqual(view.targetTextView.text, "first second third")
        XCTAssertEqual(view.referenceTextView.text, "source one source two")
        XCTAssertFalse(view.targetRegion.drawsBackground)
        XCTAssertFalse(view.referenceRegion.drawsBackground)
        XCTAssertFalse(view.targetRegion.hasVerticalScroller)
        XCTAssertFalse(view.referenceRegion.hasHorizontalScroller)
    }

    func testTwoMinuteTargetHistoryDoesNotUseACharacterSlidingWindow() {
        let view = makeView()
        let values = (1...48).map {
            "Stable translated sentence \($0) remains readable."
        }
        let model = SubtitleDisplayModel(
            stablePrimaryLines: Array(values.dropLast()),
            activePrimaryText: values.last!,
            referenceText: "latest source",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )

        view.apply(model: model)

        XCTAssertTrue(view.targetTextView.text.hasPrefix(values[0]))
        XCTAssertTrue(view.targetTextView.text.hasSuffix(values[47]))
        XCTAssertFalse(view.targetTextView.text.hasPrefix("..."))
        XCTAssertGreaterThan(view.targetTextView.text.utf16.count, 480)
    }

    func testReferenceOnlyUpdateLeavesTargetGenerationAndFramesetterUntouched() {
        let view = makeView()
        view.apply(model: model(target: "same target", reference: "one"))
        prepareTextCaches(view)
        let targetGeneration = view.targetTextView.contentGeneration
        let targetFramesetter = view.targetTextView.cachedFramesetterIdentity
        let referenceGeneration = view.referenceTextView.contentGeneration

        view.apply(model: model(target: "same target", reference: "two"))
        prepareTextCaches(view)

        XCTAssertEqual(view.targetTextView.contentGeneration, targetGeneration)
        XCTAssertEqual(
            view.targetTextView.cachedFramesetterIdentity,
            targetFramesetter
        )
        XCTAssertGreaterThan(
            view.referenceTextView.contentGeneration,
            referenceGeneration
        )
    }

    func testTargetOnlyUpdateLeavesReferenceGenerationAndFramesetterUntouched() {
        let view = makeView()
        view.apply(model: model(target: "one", reference: "same source"))
        prepareTextCaches(view)
        let targetGeneration = view.targetTextView.contentGeneration
        let referenceGeneration = view.referenceTextView.contentGeneration
        let referenceFramesetter = view.referenceTextView.cachedFramesetterIdentity

        view.apply(model: model(target: "two", reference: "same source"))
        prepareTextCaches(view)

        XCTAssertGreaterThan(
            view.targetTextView.contentGeneration,
            targetGeneration
        )
        XCTAssertEqual(
            view.referenceTextView.contentGeneration,
            referenceGeneration
        )
        XCTAssertEqual(
            view.referenceTextView.cachedFramesetterIdentity,
            referenceFramesetter
        )
    }

    func testRepeatedReferenceLayoutChangesCoalesceOneScrollRequest() {
        let view = makeView()
        view.flushPendingScrolls()
        let initialCount = view.referenceScrollScheduleCount

        for index in 0 ..< 10 {
            view.apply(layout: SubtitleLayoutSettings(
                targetAreaHeight: 264,
                targetFontSize: 36,
                targetTopOffset: 0,
                targetColor: "#FFFFFF",
                referenceAreaHeight: CGFloat(96 + index),
                referenceFontSize: 24,
                referenceBottomOffset: 0,
                referenceColor: "#F4F4F4"
            ))
        }

        XCTAssertEqual(
            view.referenceScrollScheduleCount,
            initialCount + 1
        )
        XCTAssertTrue(view.isReferenceScrollPending)
    }

    func testBothRegionsScrollToNewestBottomEdge() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 420)
        )
        view.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 120,
            targetFontSize: 36,
            targetTopOffset: 0,
            targetColor: "#FFFFFF",
            referenceAreaHeight: 80,
            referenceFontSize: 24,
            referenceBottomOffset: 0,
            referenceColor: "#F4F4F4"
        ), display: display(width: 420, height: 420))
        view.apply(model: model(
            target: String(repeating: "target words ", count: 80),
            reference: String(repeating: "reference words ", count: 80)
        ))
        view.layoutSubtreeIfNeeded()

        view.flushPendingScrolls()

        XCTAssertGreaterThan(view.targetRegion.contentView.bounds.origin.y, 0)
        XCTAssertGreaterThan(
            view.referenceRegion.contentView.bounds.origin.y,
            0
        )
        XCTAssertEqual(
            view.targetRegion.contentView.bounds.origin.y
                .truncatingRemainder(
                    dividingBy: view.targetTextView.layoutLineHeight
                ),
            0,
            accuracy: 0.01
        )
        XCTAssertEqual(
            view.referenceRegion.contentView.bounds.origin.y
                .truncatingRemainder(
                    dividingBy: view.referenceTextView.layoutLineHeight
                ),
            0,
            accuracy: 0.01
        )
    }

    func testTargetRewritePreservesReadingPositionInsteadOfJumpingToBottom() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 420)
        )
        view.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 120,
            targetFontSize: 36,
            targetTopOffset: 0,
            targetColor: "#FFFFFF",
            referenceAreaHeight: 80,
            referenceFontSize: 24,
            referenceBottomOffset: 0,
            referenceColor: "#F4F4F4"
        ), display: display(width: 420, height: 420))
        let original = String(repeating: "original translation words ", count: 40)
        view.apply(model: model(target: original, reference: "source"))
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()
        view.targetRegion.contentView.scroll(to: .zero)

        let correction = String(repeating: "corrected translation words ", count: 40)
        view.apply(model: model(target: correction, reference: "source"))
        view.flushPendingScrolls()

        XCTAssertEqual(view.targetRegion.contentView.bounds.origin.y, 0)
        XCTAssertEqual(
            view.targetTextView.text,
            model(target: correction, reference: "source").primaryText
        )
    }

    func testAppendOnlyTargetGrowthFollowsNewestEdgeWhenAlreadyAtBottom() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 420)
        )
        view.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 120,
            targetFontSize: 36,
            targetTopOffset: 0,
            targetColor: "#FFFFFF",
            referenceAreaHeight: 80,
            referenceFontSize: 24,
            referenceBottomOffset: 0,
            referenceColor: "#F4F4F4"
        ), display: display(width: 420, height: 420))
        let original = String(repeating: "stable translation words ", count: 30)
        view.apply(model: model(target: original, reference: "source"))
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()
        let originalBottom = view.targetRegion.contentView.bounds.origin.y
        XCTAssertGreaterThan(originalBottom, 0)

        view.apply(model: model(
            target: original + String(repeating: "new tail words ", count: 20),
            reference: "source"
        ))
        view.flushPendingScrolls()

        let expectedBottom = max(
            0,
            view.targetTextView.frame.height
                - view.targetRegion.contentView.bounds.height
        )
        XCTAssertEqual(
            view.targetRegion.contentView.bounds.origin.y,
            expectedBottom,
            accuracy: 0.01
        )
    }

    func testAppendOnlyTargetGrowthPreservesPositionWhenReaderScrolledUp() {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 420)
        )
        view.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 120,
            targetFontSize: 36,
            targetTopOffset: 0,
            targetColor: "#FFFFFF",
            referenceAreaHeight: 80,
            referenceFontSize: 24,
            referenceBottomOffset: 0,
            referenceColor: "#F4F4F4"
        ), display: display(width: 420, height: 420))
        let original = String(repeating: "stable translation words ", count: 30)
        view.apply(model: model(target: original, reference: "source"))
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()
        view.targetRegion.contentView.scroll(to: .zero)

        view.apply(model: model(
            target: original + String(repeating: "new tail words ", count: 20),
            reference: "source"
        ))
        view.flushPendingScrolls()

        XCTAssertEqual(view.targetRegion.contentView.bounds.origin.y, 0)
    }

    func testBilingualOverlayRendersForVisualRegression() throws {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        view.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 269,
            targetFontSize: 36,
            targetTopOffset: 0,
            targetColor: "#FFD966",
            referenceAreaHeight: 63,
            referenceFontSize: 24,
            referenceBottomOffset: 0,
            referenceColor: "#FFFFFF"
        ), display: display())
        view.apply(model: model(
            target: "AI-assisted cardiovascular intervention improves long-term outcomes — 2026.",
            reference: "人工智能辅助心血管介入治疗，可显著改善复杂病例的长期预后。"
        ))
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(
            using: .png,
            properties: [:]
        ))

        XCTAssertGreaterThan(png.count, 10_000)
        if let outputPath = ProcessInfo.processInfo.environment[
            "VOXHALO_OVERLAY_SNAPSHOT"
        ], !outputPath.isEmpty {
            try png.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    private func makeView() -> SubtitleOverlayView {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        view.apply(layout: .defaults, display: display(width: 1_200, height: 800))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func prepareTextCaches(_ view: SubtitleOverlayView) {
        view.layoutSubtreeIfNeeded()
        view.targetTextView.prepareLayoutCache()
        view.referenceTextView.prepareLayoutCache()
    }

    private func model(target: String, reference: String) -> SubtitleDisplayModel {
        SubtitleDisplayModel(
            primaryText: target,
            referenceText: reference,
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )
    }

    private func display(
        width: CGFloat = 1_440,
        height: CGFloat = 900
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            name: "Test Display",
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            scale: 2,
            isMain: true
        )
    }
}

private extension NSColor {
    var hexRGB: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
