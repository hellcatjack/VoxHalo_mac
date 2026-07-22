import AppKit
import XCTest
@testable import VoxHaloKit

@MainActor
final class SubtitleOverlayPanelTests: XCTestCase {
    func testPanelIsTransparentNonactivatingAlwaysOnTopAndClickThrough() {
        _ = NSApplication.shared
        let panel = SubtitleOverlayPanel()

        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]))
    }

    func testPanelStaysOutOfWindowMenuAndNormalCycle() {
        _ = NSApplication.shared
        let panel = SubtitleOverlayPanel()

        XCTAssertTrue(panel.isExcludedFromWindowsMenu)
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
    }
}
