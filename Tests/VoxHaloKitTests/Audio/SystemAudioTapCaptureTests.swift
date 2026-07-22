import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import VoxHaloKit

final class SystemAudioTapCaptureTests: XCTestCase {
    func testSystemTapUsesActualTapUIDPrivateAggregateAndBindsAUHAL() async throws {
        let api = FakeCoreAudioTapAPI(createdTapUID: "actual-tap-uid")
        let hal = FakeAUHAL()
        let capture = SystemAudioTapCapture(api: api, halFactory: { hal })

        try await capture.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        XCTAssertEqual(api.processTapConfiguration?.name, "VoxHalo System Audio")
        XCTAssertEqual(api.processTapConfiguration?.isPrivate, true)
        XCTAssertEqual(api.processTapConfiguration?.isMuted, false)
        XCTAssertEqual(api.processTapConfiguration?.excludesProcessObjectIDs, [])
        XCTAssertEqual(api.aggregateConfiguration?.tapUID, "actual-tap-uid")
        XCTAssertEqual(api.aggregateConfiguration?.driftCompensation, true)
        XCTAssertEqual(api.aggregateConfiguration?.tapAutoStart, false)
        XCTAssertTrue(hal.calls.contains("setDevice:202"))
        await capture.stop()
        XCTAssertTrue(api.liveTapIDs.isEmpty)
        XCTAssertTrue(api.liveAggregateIDs.isEmpty)
    }

    func testPermissionDenialAtTapCreationMapsToSystemAudioPermissionFailure() async {
        for status in SystemAudioTapCapture.permissionDeniedStatuses {
            let api = FakeCoreAudioTapAPI(
                failingAt: .createProcessTap,
                failureStatus: status
            )
            let capture = SystemAudioTapCapture(api: api, halFactory: { FakeAUHAL() })

            do {
                try await capture.start(
                    source: .systemAudio,
                    onFrame: { _ in },
                    onFailure: { _ in }
                )
                XCTFail("Expected permission failure for \(status)")
            } catch {
                XCTAssertEqual(
                    error as? AudioCaptureFailure,
                    .systemAudioPermissionDenied
                )
            }
        }
    }

    func testUnknownTapErrorStaysRedactedCoreAudioFailure() async {
        let api = FakeCoreAudioTapAPI(
            failingAt: .createProcessTap,
            failureStatus: -12_345
        )
        let capture = SystemAudioTapCapture(api: api, halFactory: { FakeAUHAL() })

        do {
            try await capture.start(
                source: .systemAudio,
                onFrame: { _ in },
                onFailure: { _ in }
            )
            XCTFail("Expected native failure")
        } catch {
            XCTAssertEqual(
                error as? AudioCaptureFailure,
                .coreAudio(operation: "createProcessTap", status: -12_345)
            )
        }
    }

    func testNoPlaybackStartReturnsPromptlyBecauseTapAutoStartIsDisabled() async throws {
        let api = FakeCoreAudioTapAPI()
        let capture = SystemAudioTapCapture(
            api: api,
            halFactory: { FakeAUHAL() }
        )
        let clock = ContinuousClock()
        let started = clock.now

        try await capture.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        XCTAssertEqual(api.aggregateConfiguration?.tapAutoStart, false)
        await capture.stop()
    }

    func testEveryHALSetupFailureRollsBackUnitAggregateAndTap() async {
        for step in FakeAUHALSetupStep.allCases {
            let api = FakeCoreAudioTapAPI()
            let hal = FakeAUHAL(failingAt: step)
            let capture = SystemAudioTapCapture(api: api, halFactory: { hal })

            do {
                try await capture.start(
                    source: .systemAudio,
                    onFrame: { _ in },
                    onFailure: { _ in }
                )
                XCTFail("Expected HAL failure at \(step)")
            } catch {}

            XCTAssertTrue(api.liveAggregateIDs.isEmpty, "aggregate leaked at \(step)")
            XCTAssertTrue(api.liveTapIDs.isEmpty, "tap leaked at \(step)")
            XCTAssertTrue(hal.calls.contains(step.call(deviceID: 202)))
            XCTAssertTrue(hal.calls.contains("disposeHALOutput") || step == .createHALOutput)
        }
    }

    func testSystemAudioUsesSharedConversionAndExactFrameAccumulator() async throws {
        let api = FakeCoreAudioTapAPI()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let hal = FakeAUHAL(format: format)
        let capture = SystemAudioTapCapture(api: api, halFactory: { hal })
        let received = expectation(description: "exact system-audio frame")
        let frames = SystemLockedFrames()
        try await capture.start(
            source: .systemAudio,
            onFrame: { frame in
                frames.append(frame)
                received.fulfill()
            },
            onFailure: { _ in }
        )

        hal.emit(
            try floatBuffer(format: format, frameCount: 2_500),
            timestamp: .init(nanosecondsSinceBoot: 10)
        )
        hal.emit(
            try floatBuffer(format: format, frameCount: 2_620),
            timestamp: .init(nanosecondsSinceBoot: 20)
        )
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frames.values[0].pcm16LE.count, 10_240)
        XCTAssertEqual(frames.values[0].callbackTimestamp.nanosecondsSinceBoot, 20)
        await capture.stop()
    }

    func testRepeatedStopIsIdempotentAndRetriesFailedNativeCleanup() async throws {
        let api = FakeCoreAudioTapAPI(
            failingAt: .destroyAggregate,
            failureCount: 1
        )
        let hal = FakeAUHAL()
        let capture = SystemAudioTapCapture(api: api, halFactory: { hal })
        try await capture.start(
            source: .systemAudio,
            onFrame: { _ in },
            onFailure: { _ in }
        )

        await capture.stop()
        XCTAssertEqual(api.liveAggregateIDs, [FakeCoreAudioTapAPI.aggregateID])
        XCTAssertTrue(api.liveTapIDs.isEmpty)
        await capture.stop()

        XCTAssertTrue(api.liveAggregateIDs.isEmpty)
        XCTAssertEqual(hal.calls.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(
            hal.calls.filter { $0 == "disposeHALOutput" }.count,
            1
        )
    }

    func testNoSystemAudioFrameCanEscapeAfterStopReturns() async throws {
        let api = FakeCoreAudioTapAPI()
        let hal = FakeAUHAL()
        let capture = SystemAudioTapCapture(api: api, halFactory: { hal })
        let late = expectation(description: "late system-audio frame")
        late.isInverted = true
        try await capture.start(
            source: .systemAudio,
            onFrame: { _ in late.fulfill() },
            onFailure: { _ in }
        )

        await capture.stop()
        hal.emit(
            try floatBuffer(
                format: hal.sourceFormat(),
                frameCount: 5_120
            ),
            timestamp: .init(nanosecondsSinceBoot: 100)
        )
        await fulfillment(of: [late], timeout: 0.05)
    }

    func testWrongSourceIsRejectedBeforeCreatingTap() async {
        let api = FakeCoreAudioTapAPI()
        let capture = SystemAudioTapCapture(api: api, halFactory: { FakeAUHAL() })
        let hardware = AudioSource(
            id: "mic",
            name: "Mic",
            kind: .hardwareInput
        )

        do {
            try await capture.start(
                source: hardware,
                onFrame: { _ in },
                onFailure: { _ in }
            )
            XCTFail("Expected source rejection")
        } catch {
            XCTAssertEqual(error as? AudioCaptureFailure, .unsupportedFormat)
        }
        XCTAssertTrue(api.calls.isEmpty)
    }

    private func floatBuffer(
        format: AVAudioFormat,
        frameCount: Int
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< Int(format.channelCount) {
            for frame in 0 ..< frameCount {
                channels[channel][frame] = 0.25
            }
        }
        return buffer
    }
}

private final class SystemLockedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapturedAudioFrame] = []
    var values: [CapturedAudioFrame] { lock.withLock { storage } }
    func append(_ frame: CapturedAudioFrame) { lock.withLock { storage.append(frame) } }
}
