import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import VoxHaloKit

@MainActor
final class DisplayCatalogTests: XCTestCase {
    func testDescriptorsUseCGDisplayUUIDNameAndPointGeometry() throws {
        let screen = FakeScreen(
            number: 88,
            localizedName: "Side Display",
            frame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
            backingScaleFactor: 2
        )
        let expectedUUID = UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )!
        let catalog = DisplayCatalog(
            provider: FakeScreenProvider(screens: [screen]),
            uuidResolver: { displayID in
                XCTAssertEqual(displayID, 88)
                return expectedUUID
            }
        )

        let value = try XCTUnwrap(catalog.displays().first)

        XCTAssertEqual(value.id, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(value.name, "Side Display")
        XCTAssertEqual(value.frame.origin.x, -1_920)
        XCTAssertEqual(value.frame.size, CGSize(width: 1_920, height: 1_080))
        XCTAssertEqual(value.scale, 2)
        XCTAssertTrue(value.isMain)
    }

    func testSavedUUIDWinsRegardlessOfArrayOrderAndMissingFallsBackToMain() {
        let left = screen(number: 1, name: "Left", x: -1_600)
        let main = screen(number: 2, name: "Main", x: 0)
        let provider = FakeScreenProvider(
            screens: [main, left],
            mainNumber: 2
        )
        let catalog = DisplayCatalog(
            provider: provider,
            uuidResolver: resolver
        )

        XCTAssertEqual(
            catalog.selectedDisplay(
                savedUUID: "00000000-0000-0000-0000-000000000001"
            ).name,
            "Left"
        )
        XCTAssertEqual(catalog.selectedDisplay(savedUUID: nil).name, "Main")
        XCTAssertEqual(
            catalog.selectedDisplay(savedUUID: "missing").name,
            "Main"
        )

        provider.replaceScreens([left, main], mainNumber: 2, notify: false)

        XCTAssertEqual(
            catalog.selectedDisplay(
                savedUUID: "00000000-0000-0000-0000-000000000001"
            ).name,
            "Left"
        )
    }

    func testAttachRemoveRearrangeAndRenameRefreshDeduplicatedSnapshots() {
        let initial = screen(number: 1, name: "Main", x: 0)
        let provider = FakeScreenProvider(screens: [initial], mainNumber: 1)
        let catalog = DisplayCatalog(
            provider: provider,
            uuidResolver: resolver
        )
        let snapshots = DisplaySnapshots()
        catalog.startObserving { snapshots.append($0) }

        provider.notifyWithoutChange()
        provider.replaceScreens([
            screen(number: 1, name: "Renamed", x: 0)
        ], mainNumber: 1)
        provider.replaceScreens([
            screen(number: 1, name: "Renamed", x: 0),
            screen(number: 2, name: "Side", x: 1_600)
        ], mainNumber: 1)
        provider.replaceScreens([
            screen(number: 1, name: "Renamed", x: 100),
            screen(number: 2, name: "Side", x: -1_500)
        ], mainNumber: 1)
        provider.replaceScreens([
            screen(number: 2, name: "Side", x: 0)
        ], mainNumber: 2)

        XCTAssertEqual(snapshots.values.count, 4)
        XCTAssertEqual(snapshots.values[0].map(\.name), ["Renamed"])
        XCTAssertEqual(snapshots.values[1].map(\.name), ["Renamed", "Side"])
        XCTAssertEqual(snapshots.values[2][0].frame.origin.x, 100)
        XCTAssertEqual(snapshots.values[2][1].frame.origin.x, -1_500)
        XCTAssertEqual(snapshots.values[3].map(\.name), ["Side"])

        catalog.stopObserving()
        provider.replaceScreens([initial], mainNumber: 1)

        XCTAssertEqual(snapshots.values.count, 4)
        XCTAssertEqual(provider.startObservingCount, 1)
        XCTAssertEqual(provider.stopObservingCount, 1)
    }

    func testRestartingObservationRemovesThePriorListener() {
        let provider = FakeScreenProvider(
            screens: [screen(number: 1, name: "Main", x: 0)]
        )
        let catalog = DisplayCatalog(
            provider: provider,
            uuidResolver: resolver
        )

        catalog.startObserving { _ in }
        catalog.startObserving { _ in }

        XCTAssertEqual(provider.startObservingCount, 2)
        XCTAssertEqual(provider.stopObservingCount, 1)
        catalog.stopObserving()
        XCTAssertEqual(provider.stopObservingCount, 2)
    }

    func testAppKitProviderRemovesScreenParameterNotificationListener() {
        let provider = AppKitScreenProvider()
        let counter = DisplayNotificationCounter()
        provider.startObservingChanges { counter.increment() }

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        XCTAssertEqual(counter.value, 1)

        provider.stopObservingChanges()
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        XCTAssertEqual(counter.value, 1)
    }

    private func screen(
        number: CGDirectDisplayID,
        name: String,
        x: CGFloat
    ) -> FakeScreen {
        FakeScreen(
            number: number,
            localizedName: name,
            frame: NSRect(x: x, y: 0, width: 1_600, height: 900),
            backingScaleFactor: number == 1 ? 2 : 1
        )
    }

    private var resolver: @Sendable (CGDirectDisplayID) -> UUID? {
        { displayID in
            UUID(uuidString: String(
                format: "00000000-0000-0000-0000-%012u",
                displayID
            ))
        }
    }
}

private final class DisplaySnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[DisplayDescriptor]] = []

    var values: [[DisplayDescriptor]] {
        lock.withLock { storage }
    }

    func append(_ value: [DisplayDescriptor]) {
        lock.withLock { storage.append(value) }
    }
}

private final class DisplayNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
