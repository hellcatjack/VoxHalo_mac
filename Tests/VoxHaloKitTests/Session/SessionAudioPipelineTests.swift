import Foundation
import XCTest
@testable import VoxHaloKit

final class SessionAudioPipelineTests: XCTestCase {
    func testQueueOverflowDropsStaleFramesAndReconnectsBeforeLaterFreshFrame() async throws {
        let fixture = try SubtitleSessionFixture(sendsSuspended: true)
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.audio.emit(sessionFrame(1, timestamp: 1))
        let firstAttempted = await waitUntil {
            await fixture.client.sendAttempts.count == 1
        }
        XCTAssertTrue(firstAttempted)

        await fixture.audio.emit((2 ... 6).map {
            sessionFrame(UInt8($0), timestamp: UInt64($0))
        })
        await fixture.client.resumeSends()
        let overloaded = await waitUntil {
            await output.recorder.statuses.filter {
                $0 == "Audio pipeline overloaded"
            }.count == 1
        }
        XCTAssertTrue(overloaded)

        await fixture.audio.emit(sessionFrame(7, timestamp: 7))

        let sentFresh = await waitUntil {
            await fixture.client.audioFrames.last?.first == 7
        }
        XCTAssertTrue(sentFresh)
        let successfulBytes = await fixture.client.audioFrames.compactMap(\.first)
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(successfulBytes, [1, 7])
        XCTAssertEqual(connectCount, 2)
        output.task.cancel()
    }

    func testNativeRingOverflowPublishesOnceAndUsesSameRecoveryPath() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.audio.fail([
            .pipelineOverloaded,
            .pipelineOverloaded,
            .pipelineOverloaded
        ])
        let overloaded = await waitUntil {
            await output.recorder.statuses.filter {
                $0 == "Audio pipeline overloaded"
            }.count == 1
        }
        XCTAssertTrue(overloaded)
        await fixture.audio.emit(sessionFrame(8, timestamp: 8))

        let sentFresh = await waitUntil {
            await fixture.client.audioFrames.last?.first == 8
        }
        XCTAssertTrue(sentFresh)
        let connectCount = await fixture.client.connectCount
        let overloadCount = await output.recorder.statuses.filter {
            $0 == "Audio pipeline overloaded"
        }.count
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(overloadCount, 1)
        output.task.cancel()
    }

    func testDeviceDisconnectionStopsWithoutSwitchingAndPreservesSubtitle() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.event(.committed("s1", "你好", sequence: 1)))
        await fixture.client.emit(.event(.translated("s1", "Hello", sequence: 2)))
        let translated = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Hello"
        }
        XCTAssertTrue(translated)

        await fixture.audio.fail(.deviceDisconnected(uid: "private-device-uid"))

        let stopped = await waitUntil {
            await fixture.coordinator.state == .stopped
        }
        XCTAssertTrue(stopped)
        let subtitle = await fixture.coordinator.currentSubtitle
        let failureCount = await output.recorder.failures.count
        let startCount = await fixture.audio.startCount
        let stopCount = await fixture.audio.stopCount
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertEqual(subtitle.primaryText, "Hello")
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        output.task.cancel()
    }

    func testConcurrentRuntimeCaptureFailuresPublishAndCleanUpOnce() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.audio.fail([
            .deviceDisconnected(uid: "one"),
            .unsupportedFormat,
            .coreAudio(operation: "secret", status: -1)
        ])

        let stopped = await waitUntil {
            await fixture.coordinator.state == .stopped
        }
        XCTAssertTrue(stopped)
        let failureCount = await output.recorder.failures.count
        let stopCount = await fixture.audio.stopCount
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        output.task.cancel()
    }

    func testCaptureFailureDuringStartAbortsTransactionWithoutRunning() async throws {
        let fixture = try SubtitleSessionFixture(
            audioFailureDuringStart: .unsupportedFormat
        )
        let output = await fixture.recordOutputs()

        do {
            try await fixture.coordinator.start(fixture.configuration)
            XCTFail("Expected startup failure")
        } catch {
            XCTAssertEqual(error as? AudioCaptureFailure, .unsupportedFormat)
        }

        let publishedStopped = await waitUntil {
            await output.recorder.states.last == .stopped
        }
        let states = await output.recorder.states
        let failures = await output.recorder.failures
        let stopCount = await fixture.audio.stopCount
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertTrue(publishedStopped)
        XCTAssertEqual(states, [.starting, .stopped])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        output.task.cancel()
    }

    func testStaleCallbacksFromPriorStartCannotAffectNewSession() async throws {
        let fixture = try SubtitleSessionFixture(
            finishOutput: .event(.final())
        )
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.coordinator.stop()
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.audio.emitFromStart(
            0,
            frame: sessionFrame(9, timestamp: 9)
        )
        await fixture.audio.failFromStart(
            0,
            failure: .deviceDisconnected(uid: "stale-private-uid")
        )
        for _ in 0 ..< 100 { await Task.yield() }

        let state = await fixture.coordinator.state
        let frames = await fixture.client.audioFrames
        let failures = await output.recorder.failures
        XCTAssertEqual(state, .running)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(failures.isEmpty)

        await fixture.audio.emit(sessionFrame(7, timestamp: 10))
        let freshSent = await waitUntil {
            await fixture.client.audioFrames.last?.first == 7
        }
        XCTAssertTrue(freshSent)
        output.task.cancel()
    }
}
