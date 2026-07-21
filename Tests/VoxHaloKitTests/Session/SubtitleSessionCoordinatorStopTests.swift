import XCTest
@testable import VoxHaloKit

final class SubtitleSessionCoordinatorStopTests: XCTestCase {
    func testStopOrdersCaptureFinishFinalDisconnectAndKeepsSubtitle() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(clock: clock)
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.event(.committed("s1", "你好", sequence: 1)))
        await fixture.client.emit(.event(.translated("s1", "Hello", sequence: 2)))
        let translated = await waitUntil {
            await fixture.coordinator.currentSubtitle.primaryText == "Hello"
        }
        XCTAssertTrue(translated)

        let stop = Task { await fixture.coordinator.stop() }
        let finishing = await waitUntil { await fixture.client.finishCount == 1 }
        XCTAssertTrue(finishing)
        await fixture.client.emit(.event(.final()) )
        await stop.value

        let calls = fixture.calls.values
        let subtitle = await fixture.coordinator.currentSubtitle
        let states = await output.recorder.states
        XCTAssertEqual(Array(calls.suffix(4)), [
            "audio.stop", "finish", "final", "disconnect"
        ])
        XCTAssertEqual(subtitle.primaryText, "Hello")
        XCTAssertEqual(states.suffix(2), [.finishing, .stopped])

        await fixture.client.emit(.event(.translated(
            "s1", "Must not arrive", sequence: 3
        )))
        for _ in 0 ..< 20 { await Task.yield() }
        let afterLateEvent = await fixture.coordinator.currentSubtitle
        XCTAssertEqual(afterLateEvent.primaryText, "Hello")
        output.task.cancel()
    }

    func testConcurrentStopsShareOneOperationAndTimeoutAt120Seconds() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(clock: clock)
        let output = await fixture.recordOutputs()
        try await fixture.coordinator.start(fixture.configuration)

        let firstCompletion = CompletionProbe()
        let secondCompletion = CompletionProbe()
        let first = Task {
            await fixture.coordinator.stop()
            await firstCompletion.complete()
        }
        let second = Task {
            await fixture.coordinator.stop()
            await secondCompletion.complete()
        }
        let waiting = await waitUntil {
            let finishCount = await fixture.client.finishCount
            let pendingSleepCount = await clock.pendingSleepCount
            return finishCount == 1 && pendingSleepCount == 1
        }
        XCTAssertTrue(waiting)
        await clock.advance(by: .seconds(119))
        for _ in 0 ..< 100 { await Task.yield() }
        let firstEarly = await firstCompletion.isComplete
        let secondEarly = await secondCompletion.isComplete
        let stateBeforeBoundary = await fixture.coordinator.state
        XCTAssertFalse(firstEarly)
        XCTAssertFalse(secondEarly)
        XCTAssertEqual(stateBeforeBoundary, .finishing)

        await clock.advance(by: .seconds(1))
        await first.value
        await second.value

        let finishCount = await fixture.client.finishCount
        let disconnectCount = await fixture.client.disconnectCount
        let statuses = await output.recorder.statuses
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(statuses.last, "Final wait timeout")
        output.task.cancel()
    }

    func testFinalWaiterIsInstalledBeforeFinishCanSynchronouslyEmitFinal() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(
            finishOutput: .event(.final()),
            clock: clock
        )
        try await fixture.coordinator.start(fixture.configuration)

        await fixture.coordinator.stop()

        let finishCount = await fixture.client.finishCount
        let disconnectCount = await fixture.client.disconnectCount
        let pendingSleeps = await clock.pendingSleepCount
        let state = await fixture.coordinator.state
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(pendingSleeps, 0)
        XCTAssertEqual(state, .stopped)
    }

    func testBackendErrorAlsoReleasesFinalWait() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(clock: clock)
        try await fixture.coordinator.start(fixture.configuration)
        let stop = Task { await fixture.coordinator.stop() }
        let waiting = await waitUntil { await fixture.client.finishCount == 1 }
        XCTAssertTrue(waiting)

        await fixture.client.emit(.event(VoxBridgeEvent(
            type: .error,
            rawType: "error",
            message: nil
        )))
        await stop.value

        let pendingSleeps = await clock.pendingSleepCount
        let disconnectCount = await fixture.client.disconnectCount
        XCTAssertEqual(pendingSleeps, 0)
        XCTAssertEqual(disconnectCount, 1)
    }

    func testDisconnectedStopSkipsFinishAndRepeatedStoppedCallsAreNoOps() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(clock: clock)
        try await fixture.coordinator.start(fixture.configuration)
        await fixture.client.emit(.connection(.disconnected))

        await fixture.coordinator.stop()
        let callsAfterFirst = fixture.calls.values
        await fixture.coordinator.stop()
        await fixture.coordinator.stop()

        let finishCount = await fixture.client.finishCount
        let state = await fixture.coordinator.state
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(fixture.calls.values, callsAfterFirst)
    }

    func testNoAudioIsSentAfterStopBegins() async throws {
        let clock = ManualSessionClock()
        let fixture = try SubtitleSessionFixture(clock: clock)
        try await fixture.coordinator.start(fixture.configuration)

        let stop = Task { await fixture.coordinator.stop() }
        let captureStopped = await waitUntil { await fixture.audio.stopCount == 1 }
        XCTAssertTrue(captureStopped)
        await fixture.audio.emit(sessionFrame(9, timestamp: 9))
        await fixture.client.emit(.event(.final()))
        await stop.value

        let audioFrames = await fixture.client.audioFrames
        XCTAssertTrue(audioFrames.isEmpty)
    }

    func testStopDuringSuspendedStartWaitsForRollbackAndCannotDamageNextSession() async throws {
        let fixture = try SubtitleSessionFixture(connectSuspended: true)
        let output = await fixture.recordOutputs()
        let start = Task { () -> Error? in
            do {
                try await fixture.coordinator.start(fixture.configuration)
                return nil
            } catch {
                return error
            }
        }
        let connecting = await waitUntil { await fixture.client.connectCount == 1 }
        XCTAssertTrue(connecting)

        let stopCompletion = CompletionProbe()
        let stop = Task {
            await fixture.coordinator.stop()
            await stopCompletion.complete()
        }
        for _ in 0 ..< 100 { await Task.yield() }
        let completedTooSoon = await stopCompletion.isComplete
        XCTAssertFalse(completedTooSoon)

        await fixture.client.resumeConnects()
        let startError = await start.value
        await stop.value
        let failures = await output.recorder.failures
        let stoppedState = await fixture.coordinator.state
        XCTAssertTrue(startError is CancellationError)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(stoppedState, .stopped)

        try await fixture.coordinator.start(fixture.configuration)
        let finalState = await fixture.coordinator.state
        let connectCount = await fixture.client.connectCount
        XCTAssertEqual(finalState, .running)
        XCTAssertEqual(connectCount, 2)
        output.task.cancel()
    }
}

private actor CompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}
