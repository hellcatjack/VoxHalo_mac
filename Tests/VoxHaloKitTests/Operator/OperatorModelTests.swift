import CoreGraphics
import Foundation
import XCTest
@testable import VoxHaloKit

@MainActor
final class OperatorModelTests: XCTestCase {
    func testExactDirectionsColorsAndTransparentOverlayOnly() throws {
        let fixture = try OperatorFixture()

        XCTAssertEqual(TranslationDirection.allCases, [
            .chineseToEnglish,
            .englishToChinese,
        ])
        XCTAssertEqual(SubtitleColorChoice.all.map(\.name), [
            "White", "Soft White", "Warm Yellow", "Cyan", "Soft Green", "Pink",
        ])
        XCTAssertEqual(SubtitleColorChoice.all.map(\.hex), [
            "#FFFFFF", "#F4F4F4", "#FFD966", "#8FE8FF", "#B7F7C4", "#FFB3D1",
        ])
        XCTAssertTrue(fixture.model.usesTransparentOverlayOnly)
    }

    func testLoadsSettingsAndFallsBackFromMissingSavedAudioBeforeStart() throws {
        let fixture = try OperatorFixture(settings: AppSettings(
            backendURL: URL(string: "wss://example.test/ws")!,
            direction: .englishToChinese,
            preferredAudioDeviceID: "missing-device",
            preferredDisplayUUID: OperatorFixture.sideDisplay.id,
            targetAreaHeight: 384,
            targetFontSize: 30,
            targetTopOffset: 150,
            targetColor: "#FFD966",
            authUsername: "operator",
            referenceAreaHeight: 144,
            referenceFontSize: 22,
            referenceBottomOffset: 96,
            referenceColor: "#8FE8FF",
            asrContextTermsText: "Elisha\r\nQwen3-ASR"
        ))

        XCTAssertEqual(fixture.model.backendURL, "wss://example.test/ws")
        XCTAssertEqual(fixture.model.direction, .englishToChinese)
        XCTAssertEqual(fixture.model.selectedAudioSourceID, AudioSource.systemAudioID)
        XCTAssertEqual(fixture.model.selectedDisplayUUID, OperatorFixture.sideDisplay.id)
        XCTAssertEqual(fixture.model.hotwordsText, "Elisha\r\nQwen3-ASR")
        XCTAssertEqual(fixture.model.layout, SubtitleLayoutSettings(
            targetAreaHeight: 384,
            targetFontSize: 30,
            targetTopOffset: 150,
            targetColor: "#FFD966",
            referenceAreaHeight: 144,
            referenceFontSize: 22,
            referenceBottomOffset: 96,
            referenceColor: "#8FE8FF"
        ))
    }

    func testUsernameAndLayoutPersistButPasswordOnlyReachesStartConfiguration() async throws {
        let fixture = try OperatorFixture()
        fixture.model.backendURL = "wss://example.test/ws"
        fixture.model.username = "operator"
        fixture.model.password = "runtime-synthetic-password"
        fixture.model.direction = .englishToChinese
        fixture.model.layout.referenceAreaHeight = 160
        fixture.model.layout.referenceFontSize = 24
        fixture.model.layout.referenceBottomOffset = 120
        fixture.model.layout.referenceColor = "#FFD966"

        await fixture.model.start()

        let capturedConfiguration = await fixture.session.configuration()
        let configuration = try XCTUnwrap(capturedConfiguration)
        XCTAssertEqual(configuration.credentials, VoxBridgeAuthCredentials(
            username: "operator",
            password: "runtime-synthetic-password"
        ))
        let saved = try fixture.store.load()
        XCTAssertEqual(saved.authUsername, "operator")
        XCTAssertEqual(saved.referenceAreaHeight, 160)
        XCTAssertEqual(saved.referenceColor, "#FFD966")
        let json = try String(contentsOf: fixture.store.settingsURL, encoding: .utf8)
        XCTAssertFalse(json.contains("runtime-synthetic-password"))
        XCTAssertFalse(json.lowercased().contains("authpassword"))
    }

    func testEnvironmentCredentialsOverrideSavedValuesWithoutPasswordPersistence() async throws {
        let fixture = try OperatorFixture(
            settings: AppSettings(authUsername: "saved-user"),
            environment: [
                "VOXBRIDGE_AUTH_USERNAME": "environment-user",
                "VOXBRIDGE_AUTH_PASSWORD": "environment-synthetic-password",
            ]
        )

        XCTAssertEqual(fixture.model.username, "environment-user")
        XCTAssertEqual(fixture.model.password, "environment-synthetic-password")
        await fixture.model.start()

        let capturedCredentials = await fixture.session.configuration()?.credentials
        let credentials = try XCTUnwrap(capturedCredentials)
        XCTAssertEqual(credentials.username, "environment-user")
        XCTAssertEqual(credentials.password, "environment-synthetic-password")
        let savedJSON = try String(contentsOf: fixture.store.settingsURL, encoding: .utf8)
        XCTAssertFalse(savedJSON.contains("environment-synthetic-password"))
        XCTAssertEqual(try fixture.store.load().authUsername, "environment-user")
    }

    func testRunningLocksSessionInputsButLeavesDisplayAndLayoutLive() async throws {
        let fixture = try OperatorFixture()
        fixture.model.password = "memory-only-value"

        await fixture.model.start()

        XCTAssertEqual(fixture.model.state, .running)
        XCTAssertFalse(fixture.model.canEditBackend)
        XCTAssertFalse(fixture.model.canEditDirection)
        XCTAssertFalse(fixture.model.canEditAudioSource)
        XCTAssertFalse(fixture.model.canEditHotwords)
        XCTAssertTrue(fixture.model.canEditDisplayAndLayout)
        fixture.model.layout.targetFontSize = 50
        fixture.model.selectedDisplayUUID = OperatorFixture.sideDisplay.id
        XCTAssertEqual(fixture.overlay.lastLayout?.targetFontSize, 50)
        XCTAssertEqual(fixture.overlay.selectedDisplayUUID, OperatorFixture.sideDisplay.id)
        let json = try String(contentsOf: fixture.store.settingsURL, encoding: .utf8)
        XCTAssertFalse(json.contains("memory-only-value"))
    }

    func testRawHotwordInputIsAutomaticallyPersisted() throws {
        let fixture = try OperatorFixture(settings: AppSettings(
            asrContextTermsText: "Elisha\r\nQwen3-ASR"
        ))

        XCTAssertEqual(fixture.model.hotwordsText, "Elisha\r\nQwen3-ASR")

        fixture.model.hotwordsText = "U.S.，Elisha"

        XCTAssertEqual(
            try fixture.store.load().asrContextTermsText,
            "U.S.，Elisha"
        )
    }

    func testStartParsesAndPassesHotwordsInOperatorOrder() async throws {
        let fixture = try OperatorFixture()
        fixture.model.hotwordsText = "Elisha, Qwen3-ASR elisha"

        await fixture.model.start()

        let capturedConfiguration = await fixture.session.configuration()
        let configuration = try XCTUnwrap(capturedConfiguration)
        XCTAssertEqual(configuration.asrContextTerms, ["Elisha", "Qwen3-ASR"])
    }

    func testInvalidHotwordInputBlocksConnectionAndRemainsEditable() async throws {
        let fixture = try OperatorFixture()
        fixture.model.hotwordsText = "not-a-term!"

        await fixture.model.start()

        let capturedConfiguration = await fixture.session.configuration()
        XCTAssertNil(capturedConfiguration)
        XCTAssertEqual(fixture.model.state, .stopped)
        XCTAssertTrue(fixture.model.status.contains("punctuation"))
        XCTAssertEqual(fixture.model.hotwordsText, "not-a-term!")
        XCTAssertTrue(fixture.model.canEditHotwords)
    }

    func testBackendStartRejectionReturnsToEditableStoppedState() async throws {
        let fixture = try OperatorFixture()
        let rejection = "ASR context accepts at most 160 characters"
        await fixture.session.setStartError(
            SubtitleSessionError.backendRejected(rejection)
        )
        fixture.model.hotwordsText = "Elisha"

        await fixture.model.start()

        XCTAssertEqual(fixture.model.state, .stopped)
        XCTAssertEqual(fixture.model.status, "Start failed: \(rejection)")
        XCTAssertEqual(fixture.model.errorMessage, fixture.model.status)
        XCTAssertTrue(fixture.model.canEditHotwords)
        let stopCount = await fixture.session.numberOfStops()
        XCTAssertEqual(stopCount, 0)
    }

    func testAuthenticationFailureReturnsToStoppedWithConciseGuidance() async throws {
        let fixture = try OperatorFixture()
        await fixture.session.setStartError(VoxBridgeAuthenticationError.rejected)
        fixture.model.password = "wrong-synthetic-password"

        await fixture.model.start()
        await fixture.session.emit(.failure("VoxBridge authentication failed."))
        await Task.yield()

        XCTAssertEqual(fixture.model.state, .stopped)
        XCTAssertEqual(
            fixture.model.status,
            "Authentication failed. Please check username/password."
        )
        XCTAssertEqual(fixture.model.errorMessage, fixture.model.status)
        XCTAssertTrue(fixture.model.canEditBackend)
        XCTAssertTrue(fixture.model.canStart)
    }

    func testInsecureEndpointWarningAndStartStopEnablementFollowState() async throws {
        let fixture = try OperatorFixture()
        fixture.model.backendURL = "ws://example.test/ws"

        XCTAssertTrue(fixture.model.endpointIsInsecure)
        XCTAssertEqual(fixture.model.endpointWarning, "ws:// is not encrypted")
        XCTAssertTrue(fixture.model.canStart)
        XCTAssertFalse(fixture.model.canStop)

        await fixture.model.start()
        XCTAssertFalse(fixture.model.canStart)
        XCTAssertTrue(fixture.model.canStop)

        let stopTask = Task { await fixture.model.stop() }
        await Task.yield()
        XCTAssertTrue(
            fixture.model.state == .finishing || fixture.model.state == .stopped
        )
        await stopTask.value
        XCTAssertEqual(fixture.model.state, .stopped)
        XCTAssertTrue(fixture.model.canStart)
        XCTAssertFalse(fixture.model.canStop)
    }

    func testPermissionDenialOffersTheMatchingSystemSettingsLink() async throws {
        let microphoneFixture = try OperatorFixture(
            sources: [
                .systemAudio,
                AudioSource(id: "mic-1", name: "USB Mic", kind: .hardwareInput),
            ]
        )
        microphoneFixture.model.selectedAudioSourceID = "mic-1"
        await microphoneFixture.session.setStartError(
            AudioCaptureFailure.microphonePermissionDenied
        )

        await microphoneFixture.model.start()

        XCTAssertEqual(
            microphoneFixture.model.permissionSettingsDestination,
            .microphone
        )

        let systemFixture = try OperatorFixture()
        await systemFixture.session.setStartError(
            AudioCaptureFailure.systemAudioPermissionDenied
        )
        await systemFixture.model.start()
        XCTAssertEqual(
            systemFixture.model.permissionSettingsDestination,
            .systemAudioRecording
        )
    }

    func testActiveDeviceRemovalStopsWithoutSwitchingDuringRunning() async throws {
        let hardware = AudioSource(
            id: "hardware-active",
            name: "Active Interface",
            kind: .hardwareInput
        )
        let fixture = try OperatorFixture(sources: [.systemAudio, hardware])
        fixture.model.selectedAudioSourceID = hardware.id
        await fixture.model.start()

        fixture.audioCatalog.replaceSources([.systemAudio])

        XCTAssertEqual(fixture.model.selectedAudioSourceID, hardware.id)
        let stopped = await waitForOperatorCondition {
            fixture.model.state == .stopped
        }
        XCTAssertTrue(stopped)
        let stopCount = await fixture.session.numberOfStops()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(fixture.model.selectedAudioSourceID, AudioSource.systemAudioID)
        XCTAssertEqual(
            fixture.model.errorMessage,
            "The selected audio source was disconnected."
        )
    }

    func testSessionSubtitleOutputIsRoutedThroughCoalescingPump() async throws {
        let scheduler = ManualMainActorScheduler()
        let fixture = try OperatorFixture(updateScheduler: scheduler)
        let subtitle = SubtitleDisplayModel(
            primaryText: "translated",
            referenceText: "recognized",
            targetLanguage: "English",
            sourceLanguage: "Chinese",
            isProcessing: false
        )

        await fixture.session.emit(.subtitle(subtitle))
        for _ in 0 ..< 1_000 where scheduler.pendingCount == 0 {
            await Task.yield()
        }
        XCTAssertNil(fixture.overlay.lastModel)

        scheduler.advance(by: .milliseconds(150))
        XCTAssertEqual(fixture.overlay.lastModel, subtitle)
    }
}

@MainActor
final class OperatorFixture {
    static let mainDisplay = DisplayDescriptor(
        id: "00000000-0000-0000-0000-000000000001",
        name: "Main",
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        scale: 2,
        isMain: true
    )
    static let sideDisplay = DisplayDescriptor(
        id: "00000000-0000-0000-0000-000000000002",
        name: "Side",
        frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        scale: 1,
        isMain: false
    )

    let temporaryDirectory: TemporaryDirectory
    let store: SettingsStore
    let session: FakeOperatorSessionCoordinator
    let audioCatalog: FakeOperatorAudioCatalog
    let displayCatalog: FakeOperatorDisplayCatalog
    let overlay: FakeOperatorOverlay
    let model: OperatorModel

    init(
        settings: AppSettings? = nil,
        environment: [String: String] = [:],
        sources: [AudioSource] = [.systemAudio],
        updateScheduler: (any MainActorScheduling)? = nil
    ) throws {
        temporaryDirectory = try TemporaryDirectory()
        store = SettingsStore(baseDirectory: temporaryDirectory.url)
        if let settings {
            try store.save(settings)
        }
        session = FakeOperatorSessionCoordinator()
        audioCatalog = FakeOperatorAudioCatalog(sources: sources)
        displayCatalog = FakeOperatorDisplayCatalog(displays: [
            Self.mainDisplay,
            Self.sideDisplay,
        ])
        overlay = FakeOperatorOverlay()
        model = OperatorModel(
            settingsStore: store,
            sessionCoordinator: session,
            audioCatalog: audioCatalog,
            displayCatalog: displayCatalog,
            overlay: overlay,
            updateScheduler: updateScheduler,
            environment: environment
        )
    }
}

actor FakeOperatorSessionCoordinator: SubtitleSessionCoordinating {
    private var continuation: AsyncStream<SubtitleSessionOutput>.Continuation?
    private var pendingOutputs: [SubtitleSessionOutput] = []
    private(set) var lastConfiguration: SubtitleSessionConfiguration?
    private(set) var stopCount = 0
    private var startError: (any Error & Sendable)?

    func outputs() -> AsyncStream<SubtitleSessionOutput> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubtitleSessionOutput.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.continuation = continuation
        for output in pendingOutputs {
            continuation.yield(output)
        }
        pendingOutputs.removeAll(keepingCapacity: true)
        return stream
    }

    func setStartError(_ error: any Error & Sendable) {
        startError = error
    }

    func configuration() -> SubtitleSessionConfiguration? {
        lastConfiguration
    }

    func numberOfStops() -> Int {
        stopCount
    }

    func start(_ configuration: SubtitleSessionConfiguration) throws {
        lastConfiguration = configuration
        if let startError { throw startError }
        continuation?.yield(.state(.running))
    }

    func stop() {
        stopCount += 1
        continuation?.yield(.state(.finishing))
        continuation?.yield(.state(.stopped))
    }

    func emit(_ output: SubtitleSessionOutput) {
        if let continuation {
            continuation.yield(output)
        } else {
            pendingOutputs.append(output)
        }
    }
}

final class FakeOperatorAudioCatalog: AudioDeviceCataloging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSources: [AudioSource]
    private var callback: (@Sendable ([AudioSource]) -> Void)?

    init(sources: [AudioSource]) {
        storedSources = sources
    }

    func sources() -> [AudioSource] {
        lock.withLock { storedSources }
    }

    func deviceID(forUID uid: String) throws -> UInt32 {
        guard sources().contains(where: { $0.id == uid }) else {
            throw AudioCaptureFailure.deviceUnavailable(uid: uid)
        }
        return 1
    }

    func validateAvailable(_ source: AudioSource) throws {
        guard sources().contains(source) else {
            throw AudioCaptureFailure.deviceUnavailable(uid: source.id)
        }
    }

    func startObserving(
        _ onChange: @escaping @Sendable ([AudioSource]) -> Void
    ) {
        lock.withLock { callback = onChange }
    }

    func stopObserving() {
        lock.withLock { callback = nil }
    }

    func replaceSources(_ value: [AudioSource]) {
        let callback = lock.withLock {
            storedSources = value
            return self.callback
        }
        callback?(value)
    }
}

@MainActor
final class FakeOperatorDisplayCatalog: DisplayCataloging {
    private(set) var storedDisplays: [DisplayDescriptor]
    private var callback: (@MainActor @Sendable ([DisplayDescriptor]) -> Void)?

    init(displays: [DisplayDescriptor]) {
        storedDisplays = displays
    }

    func displays() -> [DisplayDescriptor] { storedDisplays }

    func selectedDisplay(savedUUID: String?) -> DisplayDescriptor {
        if let savedUUID,
           let saved = storedDisplays.first(where: { $0.id == savedUUID }) {
            return saved
        }
        return storedDisplays.first(where: \.isMain) ?? storedDisplays[0]
    }

    func startObserving(
        _ handler: @escaping @MainActor @Sendable ([DisplayDescriptor]) -> Void
    ) {
        callback = handler
    }

    func stopObserving() {
        callback = nil
    }

    func replaceDisplays(_ value: [DisplayDescriptor]) {
        storedDisplays = value
        callback?(value)
    }
}

@MainActor
final class FakeOperatorOverlay: SubtitleOverlayControlling {
    private(set) var lastModel: SubtitleDisplayModel?
    private(set) var lastLayout: SubtitleLayoutSettings?
    private(set) var selectedDisplayUUID: String?
    private(set) var showEmptyCount = 0
    private(set) var closeCount = 0

    func showEmpty(on displayUUID: String?) {
        showEmptyCount += 1
        selectedDisplayUUID = displayUUID
    }

    func apply(model: SubtitleDisplayModel) {
        lastModel = model
    }

    func apply(layout: SubtitleLayoutSettings) {
        lastLayout = layout
    }

    func selectDisplay(uuid: String?) {
        selectedDisplayUUID = uuid
    }

    func close() {
        closeCount += 1
    }
}

@MainActor
private func waitForOperatorCondition(
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}
