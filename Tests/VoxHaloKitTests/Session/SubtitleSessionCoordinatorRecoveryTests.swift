import Foundation
import XCTest
@testable import VoxHaloKit

final class SubtitleSessionCoordinatorRecoveryTests: XCTestCase {
    func testExactlyEightMinuteCallbackGapReconnectsBeforeFreshFrame() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.audio.emit(sessionFrame(1, timestamp: 0))
        let sentFirst = await awaitSuccessfulAudioCount(1, fixture: fixture)
        XCTAssertTrue(sentFirst)

        await fixture.audio.emit(sessionFrame(
            2,
            timestamp: 480_000_000_000
        ))

        let sentSecond = await awaitSuccessfulAudioCount(2, fixture: fixture)
        XCTAssertTrue(sentSecond)
        let operations = await fixture.client.operations
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(Array(operations.suffix(3)), [
            "connect", "start:zh2en", "audio:2"
        ])
        XCTAssertEqual(connectCount, 2)
    }

    func testReconnectResendsTheImmutableInitialHotwordSnapshot() async throws {
        var callerTerms = ["Elisha", "Qwen3-ASR"]
        let fixture = try SubtitleSessionFixture(asrContextTerms: callerTerms)
        callerTerms[0] = "caller-mutation"
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.connection(.receiveError("network")))
        let faulted = await waitUntil {
            await fixture.coordinator.backendSessionIsFaulted
        }
        XCTAssertTrue(faulted)

        await fixture.audio.emit(sessionFrame(1))

        let sent = await awaitSuccessfulAudioCount(1, fixture: fixture)
        let contexts = await fixture.client.startContextTerms
        XCTAssertTrue(sent)
        XCTAssertEqual(contexts, [
            ["Elisha", "Qwen3-ASR"],
            ["Elisha", "Qwen3-ASR"]
        ])
    }

    func testSevenMinutesFiftyNineSecondsDoesNotReconnect() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.audio.emit(sessionFrame(1, timestamp: 1))
        let sentFirst = await awaitSuccessfulAudioCount(1, fixture: fixture)
        XCTAssertTrue(sentFirst)

        await fixture.audio.emit(sessionFrame(
            2,
            timestamp: 479_000_000_001
        ))

        let sentSecond = await awaitSuccessfulAudioCount(2, fixture: fixture)
        XCTAssertTrue(sentSecond)
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(connectCount, 1)
    }

    func testGapUsesCallbackTimestampsRatherThanDelayedDrainTime() async throws {
        let fixture = try SubtitleSessionFixture(sendsSuspended: true)
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.audio.emit(sessionFrame(1, timestamp: 100))
        let attemptedFirst = await awaitSendAttemptCount(1, fixture: fixture)
        XCTAssertTrue(attemptedFirst)
        await fixture.audio.emit(sessionFrame(
            2,
            timestamp: 480_000_000_100
        ))

        await fixture.client.resumeSends()

        let sentBoth = await awaitSuccessfulAudioCount(2, fixture: fixture)
        XCTAssertTrue(sentBoth)
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(connectCount, 2)
    }

    func testEveryRecoverableBackendFaultReconnectsOnNextFrame() async throws {
        let faults: [VoxBridgeClientOutput] = [
            .connection(.disconnected),
            .connection(.receiveError("network")),
            .event(VoxBridgeEvent(
                type: .error,
                rawType: "error",
                message: nil
            )),
            .event(VoxBridgeEvent(
                type: .error,
                rawType: "error",
                message: "temporary"
            ))
        ]

        for (index, fault) in faults.enumerated() {
            let fixture = try SubtitleSessionFixture()
            try await fixture.coordinator.start(fixture.configuration)
            await fixture.client.emit(fault)
            let markedFaulted = await waitUntil {
                await fixture.coordinator.backendSessionIsFaulted
            }
            XCTAssertTrue(markedFaulted, "fault \(index) was not observed")
            await fixture.audio.emit(sessionFrame(
                UInt8(index + 1),
                timestamp: UInt64(index + 1)
            ))

            let sent = await awaitSuccessfulAudioCount(1, fixture: fixture)
            XCTAssertTrue(sent, "fault \(index)")
            let connectCount = await fixture.client.connectCount
            XCTAssertEqual(connectCount, 2, "fault \(index)")
        }
    }

    func testFailedSendReconnectsAndRetriesTheSameFrameExactlyOnce() async throws {
        let credentials = VoxBridgeAuthCredentials(
            username: "operator",
            password: "memory-only"
        )
        let fixture = try SubtitleSessionFixture(
            direction: .englishToChinese,
            credentials: credentials,
            sendFailureCount: 1
        )
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.audio.emit(sessionFrame(9, timestamp: 9))

        let sent = await awaitSuccessfulAudioCount(1, fixture: fixture)
        XCTAssertTrue(sent)
        let attempts = await fixture.client.sendAttempts
        let requests = await fixture.client.connectionRequests
        let directions = await fixture.client.startDirections
        XCTAssertEqual(attempts, [sessionFrame(9).pcm16LE, sessionFrame(9).pcm16LE])
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.1 == credentials })
        XCTAssertEqual(directions, [.englishToChinese, .englishToChinese])
    }

    func testBurstFaultsAndQueuedFramesShareOneReconnect() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        for _ in 0 ..< 10 {
            await fixture.client.emit(.connection(.receiveError("network")))
        }
        let burstObserved = await waitUntil {
            await output.recorder.statuses.filter { $0 == "Receive error" }.count == 10
        }
        XCTAssertTrue(burstObserved)
        await fixture.audio.emit([
            sessionFrame(1, timestamp: 1),
            sessionFrame(2, timestamp: 2),
            sessionFrame(3, timestamp: 3)
        ])

        let sent = await awaitSuccessfulAudioCount(3, fixture: fixture)
        XCTAssertTrue(sent)
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(connectCount, 2)
        output.task.cancel()
    }

    func testFaultBurstDuringSuspendedReconnectStillUsesOneCachedRepair() async throws {
        let fixture = try SubtitleSessionFixture()
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.suspendConnects()
        await fixture.client.emit(.connection(.receiveError("network")))
        let faulted = await waitUntil {
            await fixture.coordinator.backendSessionIsFaulted
        }
        XCTAssertTrue(faulted)

        await fixture.audio.emit(sessionFrame(1, timestamp: 1))
        let reconnecting = await waitUntil { await fixture.client.connectCount == 2 }
        XCTAssertTrue(reconnecting)
        for _ in 0 ..< 10 {
            await fixture.client.emit(.connection(.receiveError("network")))
        }
        let burstObserved = await waitUntil {
            await output.recorder.statuses.filter { $0 == "Receive error" }.count == 11
        }
        XCTAssertTrue(burstObserved)
        await fixture.audio.emit([
            sessionFrame(2, timestamp: 2),
            sessionFrame(3, timestamp: 3)
        ])
        await fixture.client.resumeConnects()

        let sent = await awaitSuccessfulAudioCount(3, fixture: fixture)
        let connectCount = await fixture.client.connectCount
        XCTAssertTrue(sent)
        XCTAssertEqual(connectCount, 2)
        output.task.cancel()
    }

    func testClosedSocketWithoutStatusEventReconnectsBeforeSending() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.setConnected(false)

        await fixture.audio.emit(sessionFrame(4, timestamp: 4))

        let sent = await awaitSuccessfulAudioCount(1, fixture: fixture)
        let connectCount = await fixture.client.connectCount
        XCTAssertTrue(sent)
        XCTAssertEqual(connectCount, 2)
    }

    func testReconnectDoesNotResetLastSubtitle() async throws {
        let fixture = try SubtitleSessionFixture()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.event(.committed("s1", "你好", sequence: 1)))
        await fixture.client.emit(.event(.translated("s1", "Hello", sequence: 2)))
        let translated = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Hello"
        }
        XCTAssertTrue(translated)
        await fixture.client.emit(.connection(.receiveError("network")))
        let faulted = await waitUntil {
            await fixture.coordinator.backendSessionIsFaulted
        }
        XCTAssertTrue(faulted)

        await fixture.audio.emit(sessionFrame(5, timestamp: 5))

        let sent = await awaitSuccessfulAudioCount(1, fixture: fixture)
        let subtitle = await fixture.coordinator.currentSubtitle
        XCTAssertTrue(sent)
        XCTAssertEqual(subtitle.primaryText, "Hello")
    }

    private func awaitSuccessfulAudioCount(
        _ count: Int,
        fixture: SubtitleSessionFixture
    ) async -> Bool {
        await waitUntil { await fixture.client.audioFrames.count == count }
    }

    private func awaitSendAttemptCount(
        _ count: Int,
        fixture: SubtitleSessionFixture
    ) async -> Bool {
        await waitUntil { await fixture.client.sendAttempts.count == count }
    }
}
