import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import VoxHaloKit

@MainActor
final class AppEnvironmentTests: XCTestCase {
    func testLiveCaptureProgressHandlerRecordsStructuredDiagnostic() async {
        let diagnostics = RecordingDiagnosticsLogger()
        let handler = AppEnvironment.captureProgressHandler(
            diagnostics: diagnostics
        )
        let progress = AudioCapturePipelineProgress(
            callbackCount: 2,
            sourcePacketCount: 1,
            sourceFrameCount: 512,
            sourceByteCount: 4_096,
            ringWriteFailureCount: 0,
            lastNativeStatus: 0,
            convertedByteCount: 342,
            deliveredFrameCount: 0
        )

        handler(progress)

        let recorded = await waitUntil {
            await diagnostics.events.contains { event in
                guard case let .capturePipeline(value) = event else {
                    return false
                }
                return value == progress
            }
        }
        XCTAssertTrue(recorded)
    }

    func testMalformedSettingsUseDefaultsAndExposeOneConciseFailure() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(baseDirectory: directory.url)
        try FileManager.default.createDirectory(
            at: store.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.settingsURL)
        let session = FakeOperatorSessionCoordinator()
        let audio = FakeOperatorAudioCatalog(sources: [.systemAudio])
        let displays = FakeOperatorDisplayCatalog(displays: [OperatorFixture.mainDisplay])
        let overlay = FakeOperatorOverlay()

        let model = OperatorModel(
            settingsStore: store,
            sessionCoordinator: session,
            audioCatalog: audio,
            displayCatalog: displays,
            overlay: overlay,
            environment: [:]
        )

        XCTAssertEqual(model.backendURL, AppSettings.publicEndpoint.absoluteString)
        XCTAssertEqual(model.status, "Settings could not be loaded; using defaults.")
        XCTAssertEqual(model.errorMessage, model.status)
        XCTAssertEqual(model.password, "")
    }

    func testApplicationLaunchShowsEmptyOverlayWithSavedLayoutAndDisplay() throws {
        _ = NSApplication.shared
        let fixture = try EnvironmentFixture()

        fixture.environment.applicationDidFinishLaunching()

        XCTAssertEqual(fixture.overlay.showEmptyCount, 1)
        XCTAssertEqual(
            fixture.overlay.selectedDisplayUUID,
            fixture.model.selectedDisplayUUID
        )
        XCTAssertEqual(fixture.overlay.lastLayout, fixture.model.layout)
    }

    func testConcurrentShutdownRequestsShareStopAndCleanup() async throws {
        let fixture = try EnvironmentFixture()

        async let first: Void = fixture.environment.shutDown()
        async let second: Void = fixture.environment.shutDown()
        _ = await (first, second)

        let stopCount = await fixture.session.numberOfStops()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(fixture.audioCatalog.stopObservingCount, 1)
        XCTAssertEqual(fixture.displayCatalog.stopObservingCount, 1)
        XCTAssertEqual(fixture.overlay.closeCount, 1)
        XCTAssertEqual(fixture.cleanup.count, 1)
    }

    func testRepeatedLaunchNotificationDoesNotDuplicateOverlaySetup() throws {
        let fixture = try EnvironmentFixture()

        fixture.environment.applicationDidFinishLaunching()
        fixture.environment.applicationDidFinishLaunching()

        XCTAssertEqual(fixture.overlay.showEmptyCount, 1)
    }
}

@MainActor
private final class EnvironmentFixture {
    let modelFixture: OperatorFixture
    let model: OperatorModel
    let session: FakeOperatorSessionCoordinator
    let audioCatalog: CountingAudioCatalog
    let displayCatalog: CountingDisplayCatalog
    let overlay: FakeOperatorOverlay
    let cleanup = MainActorCounter()
    let environment: AppEnvironment

    init() throws {
        modelFixture = try OperatorFixture()
        session = FakeOperatorSessionCoordinator()
        audioCatalog = CountingAudioCatalog(sources: [.systemAudio])
        displayCatalog = CountingDisplayCatalog(displays: [OperatorFixture.mainDisplay])
        overlay = FakeOperatorOverlay()
        model = OperatorModel(
            settingsStore: modelFixture.store,
            sessionCoordinator: session,
            audioCatalog: audioCatalog,
            displayCatalog: displayCatalog,
            overlay: overlay,
            environment: [:]
        )
        environment = AppEnvironment(
            operatorModel: model,
            overlay: overlay,
            additionalCleanup: { [cleanup] in cleanup.increment() }
        )
    }
}

private final class CountingAudioCatalog: AudioDeviceCataloging, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSources: [AudioSource]
    private(set) var stopObservingCount = 0

    init(sources: [AudioSource]) {
        storedSources = sources
    }

    func sources() -> [AudioSource] { storedSources }
    func deviceID(forUID uid: String) -> UInt32 { 1 }
    func validateAvailable(_ source: AudioSource) throws {}
    func startObserving(
        _ onChange: @escaping @Sendable ([AudioSource]) -> Void
    ) {}
    func stopObserving() {
        lock.withLock { stopObservingCount += 1 }
    }
}

@MainActor
private final class CountingDisplayCatalog: DisplayCataloging {
    private let storedDisplays: [DisplayDescriptor]
    private(set) var stopObservingCount = 0

    init(displays: [DisplayDescriptor]) {
        storedDisplays = displays
    }

    func displays() -> [DisplayDescriptor] { storedDisplays }
    func selectedDisplay(savedUUID: String?) -> DisplayDescriptor { storedDisplays[0] }
    func startObserving(
        _ handler: @escaping @MainActor @Sendable ([DisplayDescriptor]) -> Void
    ) {}
    func stopObserving() { stopObservingCount += 1 }
}

@MainActor
private final class MainActorCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
