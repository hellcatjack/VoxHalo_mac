import AppKit
import XCTest
@testable import VoxHaloKit

@MainActor
final class SubtitleStabilityReplayTests: XCTestCase {
    func testTwoMinuteEquivalentReplayNeverDropsOrRewritesVisiblePrefix() {
        var store = SubtitleStateStore(direction: .englishToChinese)
        var acceptedText = ""

        for index in 1...48 {
            store.apply(.committed(
                "s\(index)",
                "Recognized source sentence \(index).",
                sequence: index * 4 - 3
            ))
            let translation = "Stable translated sentence \(index) remains readable."
            store.apply(.translated(
                "s\(index)",
                translation,
                sequence: index * 4 - 2
            ))

            XCTAssertTrue(
                store.current.primaryText.hasPrefix(acceptedText),
                "append \(index) displaced an already visible prefix"
            )
            acceptedText = store.current.primaryText

            store.apply(.updated(
                "s\(index)",
                "Backend-revised source sentence \(index).",
                sequence: index * 4 - 1
            ))
            store.apply(.translated(
                "s\(index)",
                "Structurally rewritten translation \(index) should stay canonical only.",
                sequence: index * 4
            ))
            XCTAssertEqual(
                store.current.primaryText,
                acceptedText,
                "revision \(index) rewrote the visible reading stream"
            )
        }

        XCTAssertGreaterThan(store.current.primaryText.utf16.count, 480)
        XCTAssertTrue(store.current.primaryText.hasPrefix("Stable translated sentence 1"))
        XCTAssertTrue(store.current.primaryText.hasSuffix("sentence 48 remains readable."))
        XCTAssertEqual(store.current.primarySegments.count, 48)
    }

    func testTwoMinuteReplayKeepsRenderedPrefixAndScrollAnchorStable() throws {
        let view = SubtitleOverlayView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 500)
        )
        view.apply(
            layout: SubtitleLayoutSettings(
                targetAreaHeight: 150,
                targetFontSize: 32,
                targetTopOffset: 0,
                targetColor: "#FFFFFF",
                referenceAreaHeight: 80,
                referenceFontSize: 22,
                referenceBottomOffset: 0,
                referenceColor: "#F4F4F4"
            ),
            display: DisplayDescriptor(
                id: "REPLAY-DISPLAY",
                name: "Replay Display",
                frame: CGRect(x: 0, y: 0, width: 720, height: 500),
                scale: 2,
                isMain: true
            )
        )
        view.layoutSubtreeIfNeeded()
        view.flushPendingScrolls()

        var store = SubtitleStateStore(direction: .englishToChinese)
        var renderedPrefix = ""
        var previousBottom: CGFloat = 0

        for index in 1...48 {
            store.apply(.committed(
                "s\(index)",
                "Replay source sentence \(index).",
                sequence: index * 3 - 2
            ))
            view.apply(model: store.current)

            store.apply(.translated(
                "s\(index)",
                "Replay translation sentence \(index) remains fixed.",
                sequence: index * 3 - 1
            ))
            view.apply(model: store.current)
            view.flushPendingScrolls()

            XCTAssertTrue(view.targetTextView.text.hasPrefix(renderedPrefix))
            XCTAssertGreaterThanOrEqual(
                view.targetRegion.contentView.bounds.origin.y,
                previousBottom
            )
            renderedPrefix = view.targetTextView.text
            previousBottom = view.targetRegion.contentView.bounds.origin.y

            let generation = view.targetTextView.contentGeneration
            let scrollOrigin = view.targetRegion.contentView.bounds.origin
            store.apply(.translated(
                "s\(index)",
                "A backend rewrite for sentence \(index) must not reflow the screen.",
                sequence: index * 3
            ))
            view.apply(model: store.current)
            view.flushPendingScrolls()

            XCTAssertEqual(view.targetTextView.contentGeneration, generation)
            XCTAssertEqual(view.targetRegion.contentView.bounds.origin, scrollOrigin)
        }

        XCTAssertEqual(view.targetTextView.text, store.current.primaryText)
        XCTAssertGreaterThan(view.targetTextView.text.utf16.count, 480)

        if let outputPath = ProcessInfo.processInfo.environment[
            "VOXHALO_REPLAY_SNAPSHOT"
        ], !outputPath.isEmpty {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                view.bitmapImageRepForCachingDisplay(in: view.bounds)
            )
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(
                using: .png,
                properties: [:]
            ))
            try png.write(to: URL(fileURLWithPath: outputPath))
        }
    }
}
