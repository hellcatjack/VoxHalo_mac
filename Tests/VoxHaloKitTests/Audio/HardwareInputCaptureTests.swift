import AVFAudio
import CoreAudio
import Foundation
import XCTest
@testable import VoxHaloKit

final class HardwareInputCaptureTests: XCTestCase {
    func testHardwareCaptureUsesRequiredAUHALOrderAndResolvesUIDAtStart() async throws {
        let fixture = fixture(deviceID: 42)
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        XCTAssertEqual(fixture.hal.calls, [
            "createHALOutput", "enableInput:bus1", "disableOutput:bus0",
            "setDevice:42", "readFormat:output:bus1", "readMaxFrames",
            "allocateRing", "installInputCallback", "initialize", "start"
        ])
        XCTAssertEqual(fixture.factory.count, 1)
        await fixture.capture.stop()
    }

    func testUIDIsResolvedAgainAfterEveryStopInsteadOfCachingDeviceID() async throws {
        let source = hardwareSource()
        let hardware = FakeCoreAudioHardware(devices: [device(42)])
        let catalog = CoreAudioDeviceCatalog(hardware: hardware)
        let first = FakeAUHAL()
        let second = FakeAUHAL()
        let factory = AUHALFactoryProbe([first, second])
        let capture = HardwareInputCapture(
            deviceCatalog: catalog,
            permissionProvider: allowedPermission(),
            halFactory: { factory.make() }
        )

        try await capture.start(source: source, onFrame: { _ in }, onFailure: { _ in })
        await capture.stop()
        hardware.replaceDevices([device(84)], notify: false)
        try await capture.start(source: source, onFrame: { _ in }, onFailure: { _ in })

        XCTAssertTrue(first.calls.contains("setDevice:42"))
        XCTAssertTrue(second.calls.contains("setDevice:84"))
        await capture.stop()
    }

    func testMicrophoneDenialHappensBeforeAUHALCreation() async {
        let calls = CallRecorder()
        let denied = FakeAudioPermissionProvider(
            calls: calls,
            error: AudioCaptureFailure.microphonePermissionDenied
        )
        let hal = FakeAUHAL()
        let factory = AUHALFactoryProbe([hal])
        let hardware = FakeCoreAudioHardware(devices: [device(42)])
        let capture = HardwareInputCapture(
            deviceCatalog: CoreAudioDeviceCatalog(hardware: hardware),
            permissionProvider: denied,
            halFactory: { factory.make() }
        )

        do {
            try await capture.start(
                source: hardwareSource(),
                onFrame: { _ in },
                onFailure: { _ in }
            )
            XCTFail("Expected microphone permission denial")
        } catch {
            XCTAssertEqual(
                error as? AudioCaptureFailure,
                .microphonePermissionDenied
            )
        }

        XCTAssertEqual(factory.count, 0)
        XCTAssertEqual(calls.values, ["permission:hardwareInput"])
    }

    func testSourceFormatConversionAccumulatesOneExactBackendFrame() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let fixture = fixture(deviceID: 42, format: format)
        let received = expectation(description: "one complete backend frame")
        let frames = LockedFrames()
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { frame in
                frames.append(frame)
                received.fulfill()
            },
            onFailure: { failure in
                XCTFail("Unexpected capture failure: \(failure)")
            }
        )

        fixture.hal.emit(
            try floatBuffer(format: format, frameCount: 2_000, value: 0.5),
            timestamp: .init(nanosecondsSinceBoot: 10)
        )
        fixture.hal.emit(
            try floatBuffer(format: format, frameCount: 3_120, value: 0.5),
            timestamp: .init(nanosecondsSinceBoot: 20)
        )
        await fulfillment(of: [received], timeout: 2)

        let frame = try XCTUnwrap(frames.values.first)
        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frame.pcm16LE.count, VoxBridgePCMFormat.frameByteCount)
        XCTAssertEqual(frame.callbackTimestamp.nanosecondsSinceBoot, 20)
        let firstSample = try XCTUnwrap(samples(in: frame.pcm16LE).first)
        XCTAssertEqual(Int(firstSample), 16_384, accuracy: 2)
        await fixture.capture.stop()
    }

    func testNoFrameCallbackCanEscapeAfterStopReturns() async throws {
        let fixture = fixture(deviceID: 42)
        let callback = expectation(description: "late callback")
        callback.isInverted = true
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in callback.fulfill() },
            onFailure: { _ in }
        )

        await fixture.capture.stop()
        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 5_120,
                value: 0.25
            ),
            timestamp: .init(nanosecondsSinceBoot: 100)
        )
        await fulfillment(of: [callback], timeout: 0.05)
    }

    func testRemovedActiveDeviceReportsDisconnectAndStopsDelivery() async throws {
        let fixture = fixture(deviceID: 42)
        let disconnected = expectation(description: "device disconnected")
        let failures = LockedFailures()
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in },
            onFailure: { failure in
                failures.append(failure)
                disconnected.fulfill()
            }
        )

        fixture.hardware.replaceDevices([])
        await fulfillment(of: [disconnected], timeout: 2)

        XCTAssertEqual(failures.values, [.deviceDisconnected(uid: "mic")])
        await fixture.capture.stop()
    }

    func testNativeRingOverflowReportsPipelineOverloadWithoutStoppingCapture() async throws {
        let fixture = fixture(deviceID: 42)
        let overloaded = expectation(description: "pipeline overload")
        let received = expectation(description: "capture continues")
        let failures = LockedFailures()
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in received.fulfill() },
            onFailure: { failure in
                failures.append(failure)
                overloaded.fulfill()
            }
        )

        fixture.hal.emitOverflow()
        await fulfillment(of: [overloaded], timeout: 2)
        XCTAssertEqual(failures.values, [.pipelineOverloaded])

        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 2_000,
                value: 0.2
            ),
            timestamp: .init(nanosecondsSinceBoot: 2)
        )
        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 3_120,
                value: 0.2
            ),
            timestamp: .init(nanosecondsSinceBoot: 3)
        )
        await fulfillment(of: [received], timeout: 2)
        await fixture.capture.stop()
    }

    func testOverflowDiscardsPreOverflowConverterAndAccumulatorState() async throws {
        let fixture = fixture(deviceID: 42)
        let overloaded = expectation(description: "pipeline overload")
        let received = expectation(description: "fresh complete frame")
        let frames = LockedFrames()
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { frame in
                frames.append(frame)
                received.fulfill()
            },
            onFailure: { failure in
                if failure == .pipelineOverloaded {
                    overloaded.fulfill()
                }
            }
        )

        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 2_000,
                value: 0.1
            ),
            timestamp: .init(nanosecondsSinceBoot: 1)
        )
        fixture.hal.emitOverflow()
        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 3_120,
                value: 0.2
            ),
            timestamp: .init(nanosecondsSinceBoot: 2)
        )
        await fulfillment(of: [overloaded], timeout: 2)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(frames.values.isEmpty)

        fixture.hal.emit(
            try floatBuffer(
                format: fixture.hal.sourceFormat(),
                frameCount: 2_000,
                value: 0.2
            ),
            timestamp: .init(nanosecondsSinceBoot: 3)
        )
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(
            frames.values.first?.callbackTimestamp.nanosecondsSinceBoot,
            3
        )
        await fixture.capture.stop()
    }

    func testRepeatedStopTearsDownNativeResourcesExactlyOnce() async throws {
        let fixture = fixture(deviceID: 42)
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        await fixture.capture.stop()
        await fixture.capture.stop()

        XCTAssertEqual(fixture.hal.calls.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(
            fixture.hal.calls.filter { $0 == "disposeHALOutput" }.count,
            1
        )
        XCTAssertEqual(fixture.hardware.stopObservingCount, 1)
    }

    func testConcurrentStopsShareTeardownAndBothReturnAfterDisposal() async throws {
        let fixture = fixture(deviceID: 42)
        try await fixture.capture.start(
            source: fixture.source,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        async let first: Void = fixture.capture.stop()
        async let second: Void = fixture.capture.stop()
        _ = await (first, second)

        XCTAssertEqual(fixture.hal.calls.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(
            fixture.hal.calls.filter { $0 == "disposeHALOutput" }.count,
            1
        )
    }

    func testEveryAUHALSetupFailureRollsBackCompletedCallsInReverseOrder() async {
        for failedStep in FakeAUHALSetupStep.allCases {
            let fixture = fixture(deviceID: 42, failingAt: failedStep)

            do {
                try await fixture.capture.start(
                    source: fixture.source,
                    onFrame: { _ in },
                    onFailure: { _ in }
                )
                XCTFail("Expected failure at \(failedStep)")
            } catch {}

            let failureIndex = FakeAUHALSetupStep.allCases.firstIndex(
                of: failedStep
            )!
            let steps = Array(
                FakeAUHALSetupStep.allCases.prefix(failureIndex + 1)
            )
            let completed = steps.dropLast()
            let expectedSetup = steps.map { $0.call(deviceID: 42) }
            let expectedRollback = completed.reversed().map {
                $0.rollback(deviceID: 42)
            }
            XCTAssertEqual(
                fixture.hal.calls,
                expectedSetup + expectedRollback,
                "failure at \(failedStep)"
            )
        }
    }

    private struct Fixture {
        let capture: HardwareInputCapture
        let source: AudioSource
        let hardware: FakeCoreAudioHardware
        let hal: FakeAUHAL
        let factory: AUHALFactoryProbe
    }

    private func fixture(
        deviceID: AudioDeviceID,
        format: AVAudioFormat = FakeAUHAL.defaultFormat(),
        failingAt step: FakeAUHALSetupStep? = nil
    ) -> Fixture {
        let source = hardwareSource()
        let hardware = FakeCoreAudioHardware(devices: [device(deviceID)])
        let hal = FakeAUHAL(format: format, failingAt: step)
        let factory = AUHALFactoryProbe([hal])
        let capture = HardwareInputCapture(
            deviceCatalog: CoreAudioDeviceCatalog(hardware: hardware),
            permissionProvider: allowedPermission(),
            halFactory: { factory.make() }
        )
        return Fixture(
            capture: capture,
            source: source,
            hardware: hardware,
            hal: hal,
            factory: factory
        )
    }

    private func allowedPermission() -> FakeAudioPermissionProvider {
        FakeAudioPermissionProvider(calls: CallRecorder())
    }

    private func hardwareSource() -> AudioSource {
        AudioSource(id: "mic", name: "USB Mic", kind: .hardwareInput)
    }

    private func device(_ id: AudioDeviceID) -> CoreAudioDeviceDescription {
        CoreAudioDeviceDescription(
            id: id,
            uid: "mic",
            name: "USB Mic",
            inputChannels: 2,
            isAlive: true
        )
    }

    private func floatBuffer(
        format: AVAudioFormat,
        frameCount: Int,
        value: Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        if format.isInterleaved {
            for index in 0 ..< frameCount * Int(format.channelCount) {
                channels[0][index] = value
            }
        } else {
            for channel in 0 ..< Int(format.channelCount) {
                for index in 0 ..< frameCount {
                    channels[channel][index] = value
                }
            }
        }
        return buffer
    }

    private func samples(in data: Data) -> [Int16] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
        }
    }
}

private final class LockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapturedAudioFrame] = []

    var values: [CapturedAudioFrame] { lock.withLock { storage } }
    func append(_ value: CapturedAudioFrame) { lock.withLock { storage.append(value) } }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioCaptureFailure] = []

    var values: [AudioCaptureFailure] { lock.withLock { storage } }
    func append(_ value: AudioCaptureFailure) { lock.withLock { storage.append(value) } }
}
