import AppKit
import XCTest
@testable import VoxHaloKit

@MainActor
final class SubtitleOverlayControllerTests: XCTestCase {
    func testShowEmptyFillsSelectedScreenInPointsWithoutActivation() {
        _ = NSApplication.shared
        let main = screen(number: 1, name: "Main", frame: .init(
            x: 0, y: 0, width: 1_440, height: 900
        ), scale: 2)
        let side = screen(number: 2, name: "Side", frame: .init(
            x: -1_920, y: 120, width: 1_920, height: 1_080
        ), scale: 2)
        let fixture = makeController(
            screens: [main, side],
            mainNumber: 1
        )

        fixture.controller.showEmpty(
            on: "00000000-0000-0000-0000-000000000002"
        )

        XCTAssertEqual(fixture.panel.frame, side.frame)
        XCTAssertEqual(fixture.panel.frame.width, 1_920)
        XCTAssertEqual(fixture.controller.activeDisplay?.id,
                       "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(fixture.view.targetTextView.text, "")
        XCTAssertEqual(fixture.view.referenceTextView.text, "")
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertFalse(fixture.panel.canBecomeKey)
        fixture.controller.close()
    }

    func testSelectedScreenRemovalMovesOverlayToMainDisplay() {
        _ = NSApplication.shared
        let main = screen(number: 1, name: "Main", frame: .init(
            x: 0, y: 0, width: 1_600, height: 900
        ), scale: 2)
        let side = screen(number: 2, name: "Side", frame: .init(
            x: -1_200, y: 0, width: 1_200, height: 800
        ), scale: 1)
        let fixture = makeController(
            screens: [side, main],
            mainNumber: 1
        )
        fixture.controller.showEmpty(
            on: "00000000-0000-0000-0000-000000000002"
        )

        fixture.provider.replaceScreens([main], mainNumber: 1)

        XCTAssertEqual(fixture.panel.frame, main.frame)
        XCTAssertEqual(fixture.controller.activeDisplay?.name, "Main")
        fixture.controller.close()
    }

    func testDisplayLayoutAndModelChangesApplyLiveWithoutLosingTransparency() {
        _ = NSApplication.shared
        let main = screen(number: 1, name: "Main", frame: .init(
            x: 10, y: 20, width: 1_200, height: 800
        ), scale: 1)
        let fixture = makeController(screens: [main], mainNumber: 1)
        fixture.controller.showEmpty(on: nil)

        fixture.controller.apply(layout: SubtitleLayoutSettings(
            targetAreaHeight: 420,
            targetFontSize: 28,
            targetTopOffset: 80,
            targetColor: "#FFD966",
            referenceAreaHeight: 132,
            referenceFontSize: 21,
            referenceBottomOffset: 88,
            referenceColor: "#8FE8FF"
        ))
        fixture.controller.apply(model: SubtitleDisplayModel(
            primaryText: "translated",
            referenceText: "recognized",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        ))
        fixture.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(fixture.view.targetRegion.frame.height, 420)
        XCTAssertEqual(fixture.view.referenceRegion.frame.height, 132)
        XCTAssertEqual(fixture.view.targetTextView.text, "translated")
        XCTAssertEqual(fixture.view.referenceTextView.text, "recognized")
        XCTAssertEqual(fixture.panel.backgroundColor, .clear)
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        fixture.controller.close()
    }

    func testCloseStopsDisplayObservationAndHidesPanel() {
        _ = NSApplication.shared
        let fixture = makeController(screens: [
            screen(number: 1, name: "Main", frame: .init(
                x: 0, y: 0, width: 1_200, height: 800
            ), scale: 2)
        ], mainNumber: 1)
        fixture.controller.showEmpty(on: nil)

        fixture.controller.close()

        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.provider.stopObservingCount, 1)
        fixture.provider.notifyWithoutChange()
        XCTAssertFalse(fixture.panel.isVisible)
    }

    private func makeController(
        screens: [FakeScreen],
        mainNumber: CGDirectDisplayID
    ) -> (
        controller: SubtitleOverlayController,
        panel: SubtitleOverlayPanel,
        view: SubtitleOverlayView,
        provider: FakeScreenProvider
    ) {
        let provider = FakeScreenProvider(
            screens: screens,
            mainNumber: mainNumber
        )
        let catalog = DisplayCatalog(
            provider: provider,
            uuidResolver: { displayID in
                UUID(uuidString: String(
                    format: "00000000-0000-0000-0000-%012u",
                    displayID
                ))
            }
        )
        let panel = SubtitleOverlayPanel()
        let view = SubtitleOverlayView(frame: .zero)
        let controller = SubtitleOverlayController(
            displayCatalog: catalog,
            panel: panel,
            overlayView: view
        )
        return (controller, panel, view, provider)
    }

    private func screen(
        number: CGDirectDisplayID,
        name: String,
        frame: NSRect,
        scale: CGFloat
    ) -> FakeScreen {
        FakeScreen(
            number: number,
            localizedName: name,
            frame: frame,
            backingScaleFactor: scale
        )
    }
}
