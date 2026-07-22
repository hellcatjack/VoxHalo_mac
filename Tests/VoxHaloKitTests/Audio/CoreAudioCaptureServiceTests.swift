import XCTest
@testable import VoxHaloKit

final class CoreAudioCaptureServiceTests: XCTestCase {
    func testSelectsExactlyOneCaptureForSourceAndForwardsCallbacks() async throws {
        let systemCalls = CallRecorder()
        let hardwareCalls = CallRecorder()
        let system = FakeAudioCapture(calls: systemCalls)
        let hardware = FakeAudioCapture(calls: hardwareCalls)
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: hardware
        )
        let received = expectation(description: "forwarded frame")
        let expected = CapturedAudioFrame(
            pcm16LE: Data([1, 2]),
            callbackTimestamp: .init(nanosecondsSinceBoot: 3)
        )

        try await service.start(
            source: .systemAudio,
            onFrame: { frame in
                XCTAssertEqual(frame, expected)
                received.fulfill()
            },
            onFailure: { _ in }
        )
        await system.emit(expected)
        await fulfillment(of: [received], timeout: 2)

        let systemStartCount = await system.startCount
        let hardwareStartCount = await hardware.startCount
        XCTAssertEqual(systemStartCount, 1)
        XCTAssertEqual(hardwareStartCount, 0)
        await service.stop()
    }

    func testSecondStartCannotSwitchSourceWhileFirstIsLive() async throws {
        let system = FakeAudioCapture(calls: CallRecorder())
        let hardware = FakeAudioCapture(calls: CallRecorder())
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: hardware
        )
        try await service.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        do {
            try await service.start(
                source: AudioSource(
                    id: "mic",
                    name: "Mic",
                    kind: .hardwareInput
                ),
                onFrame: { _ in },
                onFailure: { _ in }
            )
            XCTFail("Expected one-live-capture guard")
        } catch {}

        let systemStopCount = await system.stopCount
        let hardwareStartCount = await hardware.startCount
        XCTAssertEqual(systemStopCount, 0)
        XCTAssertEqual(hardwareStartCount, 0)
        await service.stop()
    }

    func testHardwareSourceSelectsHardwareCaptureAndForwardsFailure() async throws {
        let system = FakeAudioCapture(calls: CallRecorder())
        let hardware = FakeAudioCapture(calls: CallRecorder())
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: hardware
        )
        let failed = expectation(description: "forwarded hardware failure")
        let failures = ServiceLockedFailures()
        let source = AudioSource(
            id: "mic",
            name: "Mic",
            kind: .hardwareInput
        )
        try await service.start(
            source: source,
            onFrame: { _ in },
            onFailure: { failure in
                failures.append(failure)
                failed.fulfill()
            }
        )

        await hardware.fail(.deviceDisconnected(uid: "mic"))
        await fulfillment(of: [failed], timeout: 2)

        let systemStartCount = await system.startCount
        let hardwareStartCount = await hardware.startCount
        XCTAssertEqual(systemStartCount, 0)
        XCTAssertEqual(hardwareStartCount, 1)
        XCTAssertEqual(failures.values, [.deviceDisconnected(uid: "mic")])
        await service.stop()
    }

    func testStopInvalidatesLateChildCallbacks() async throws {
        let system = FakeAudioCapture(calls: CallRecorder())
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: FakeAudioCapture(calls: CallRecorder())
        )
        let late = expectation(description: "late frame")
        late.isInverted = true
        try await service.start(
            source: .systemAudio,
            onFrame: { _ in late.fulfill() },
            onFailure: { _ in }
        )

        await service.stop()
        await system.emitFromStart(
            0,
            frame: CapturedAudioFrame(
                pcm16LE: Data([9]),
                callbackTimestamp: .init(nanosecondsSinceBoot: 9)
            )
        )
        await fulfillment(of: [late], timeout: 0.05)
    }

    func testApplicationTerminationRetriesUntilNoTapAggregateOrUnitRemains() async throws {
        let api = FakeCoreAudioTapAPI(
            failingAt: .destroyAggregate,
            failureCount: 1
        )
        let hal = FakeAUHAL()
        let system = SystemAudioTapCapture(api: api, halFactory: { hal })
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: FakeAudioCapture(calls: CallRecorder())
        )
        try await service.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        await service.stop()
        await service.stop()

        XCTAssertTrue(api.liveTapIDs.isEmpty)
        XCTAssertTrue(api.liveAggregateIDs.isEmpty)
        XCTAssertEqual(
            hal.calls.filter { $0 == "disposeHALOutput" }.count,
            1
        )
    }

    func testSwitchingToHardwareDoesNotForgetPendingSystemTapCleanup() async throws {
        let api = FakeCoreAudioTapAPI(
            failingAt: .destroyAggregate,
            failureCount: 2
        )
        let system = SystemAudioTapCapture(
            api: api,
            halFactory: { FakeAUHAL() }
        )
        let hardware = FakeAudioCapture(calls: CallRecorder())
        let service = CoreAudioCaptureService(
            systemAudioCapture: system,
            hardwareInputCapture: hardware
        )
        try await service.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )
        await service.stop()
        XCTAssertFalse(api.liveAggregateIDs.isEmpty)

        try await service.start(
            source: AudioSource(
                id: "mic",
                name: "Mic",
                kind: .hardwareInput
            ),
            onFrame: { _ in },
            onFailure: { _ in }
        )
        await service.stop()

        XCTAssertTrue(api.liveAggregateIDs.isEmpty)
        XCTAssertTrue(api.liveTapIDs.isEmpty)
    }
}

private final class ServiceLockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioCaptureFailure] = []
    var values: [AudioCaptureFailure] { lock.withLock { storage } }
    func append(_ failure: AudioCaptureFailure) {
        lock.withLock { storage.append(failure) }
    }
}
