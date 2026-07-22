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
        hostingView.frame = NSRect(
            origin: .zero,
            size: OperatorView.preferredContentSize
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.width,
            OperatorView.preferredContentSize.width
        )
        XCTAssertLessThanOrEqual(
            hostingView.fittingSize.height,
            OperatorView.preferredContentSize.height
        )
        XCTAssertTrue(scrollViews(in: hostingView).isEmpty)
    }

    func testViewDeclaresEveryRequiredNativeControl() {
        XCTAssertEqual(
            OperatorView.controlIdentifiers,
            Set([
                "operator.root",
                "operator.backend",
                "operator.username",
                "operator.password",
                "operator.rememberPassword",
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
        XCTAssertTrue(OperatorView.hotwordSummary.contains("auto-saved"))
        XCTAssertGreaterThanOrEqual(OperatorView.hotwordEditorHeight, 44)
        XCTAssertLessThanOrEqual(OperatorView.hotwordEditorHeight, 56)
    }

    func testViewExposesExactLayoutRanges() {
        XCTAssertEqual(OperatorView.targetAreaHeightRange, 120...640)
        XCTAssertEqual(OperatorView.targetFontSizeRange, 18...56)
        XCTAssertEqual(OperatorView.targetTopOffsetRange, 0...900)
        XCTAssertEqual(OperatorView.referenceAreaHeightRange, 48...360)
        XCTAssertEqual(OperatorView.referenceFontSizeRange, 16...42)
        XCTAssertEqual(OperatorView.referenceBottomOffsetRange, 0...900)
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

    func testWindowSizingFitsCommonSmallScreenWithoutScrolling() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_024, height: 675)

        let size = OperatorWindowLayout.contentSize(fitting: visibleFrame)

        XCTAssertLessThanOrEqual(size.width, visibleFrame.width - 32)
        XCTAssertLessThanOrEqual(size.height, visibleFrame.height - 48)
        XCTAssertGreaterThanOrEqual(size.width, 900)
        XCTAssertGreaterThanOrEqual(size.height, 500)
    }

    func testOperatorWindowRendersAtPreferredAndMinimumSizes() throws {
        _ = NSApplication.shared
        let saved = SavedPassword(
            endpoint: AppSettings.publicEndpoint.absoluteString,
            username: "admin",
            password: "synthetic-visual-password"
        )
        let fixture = try OperatorFixture(savedPassword: saved)
        fixture.model.hotwordsText = "Qwen3-ASR, Elisha, cardiovascular"
        let outputDirectory = ProcessInfo.processInfo.environment[
            "VOXHALO_OPERATOR_SNAPSHOT_DIR"
        ].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        for (name, size) in [
            ("preferred", OperatorView.preferredContentSize),
            ("minimum", OperatorView.minimumContentSize),
        ] {
            let hostingView = NSHostingView(
                rootView: OperatorView(model: fixture.model)
            )
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()

            XCTAssertTrue(scrollViews(in: hostingView).isEmpty, name)
            let bitmap = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds),
                name
            )
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let png = try XCTUnwrap(
                bitmap.representation(using: .png, properties: [:]),
                name
            )
            XCTAssertGreaterThan(png.count, 20_000, name)
            if let outputDirectory {
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                try png.write(
                    to: outputDirectory.appendingPathComponent(
                        "voxhalo-settings-\(name).png"
                    ))
            }
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result = view is NSScrollView ? [view as! NSScrollView] : []
        for child in view.subviews {
            result.append(contentsOf: scrollViews(in: child))
        }
        return result
    }
}
